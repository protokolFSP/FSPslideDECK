#!/usr/bin/env bash
set -euo pipefail

# scripts/generate_decks.sh
# Generates PPTX + PDF slide decks from TXT transcripts using notebooklm-mcp-cli.
# Idempotent: skips if outputs already exist.
#
# Env vars:
#   MAX_PER_RUN (default: 15)
#   TRANSCRIPT_REPO (default: https://github.com/protokolFSP/FSPtranskript)
#   TRANSCRIPT_DIR (default: transcripts)
#   WORK_DIR (default: work)
#   OUT_PPTX_DIR (default: decks)
#   OUT_PDF_DIR (default: decks_pdf)
#   MANIFEST_PATH (default: manifest/manifest.csv)
#   NLM_NOTEBOOK_ALIAS (default: deckfactory)
#   NLM_NOTEBOOK_NAME (default: Deck Factory)
#
# Requirements on runner:
#   - notebooklm-mcp-cli installed and logged in (nlm login)
#   - libreoffice (soffice) installed
#   - git

MAX_PER_RUN="${MAX_PER_RUN:-15}"
TRANSCRIPT_REPO="${TRANSCRIPT_REPO:-https://github.com/protokolFSP/FSPtranskript}"
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-transcripts}"
WORK_DIR="${WORK_DIR:-work}"
OUT_PPTX_DIR="${OUT_PPTX_DIR:-decks}"
OUT_PDF_DIR="${OUT_PDF_DIR:-decks_pdf}"
MANIFEST_PATH="${MANIFEST_PATH:-manifest/manifest.csv}"
NLM_NOTEBOOK_ALIAS="${NLM_NOTEBOOK_ALIAS:-deckfactory}"
NLM_NOTEBOOK_NAME="${NLM_NOTEBOOK_NAME:-Deck Factory}"

SRC_REPO_DIR="${WORK_DIR}/FSPtranskript"
SRC_TRANSCRIPTS_DIR="${SRC_REPO_DIR}/${TRANSCRIPT_DIR}"

log() { printf '%s %s\n' "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')]" "$*"; }
warn() { printf '%s %s\n' "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')]" "WARN: $*" >&2; }
err() { printf '%s %s\n' "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')]" "ERROR: $*" >&2; }

ensure_dirs() {
  mkdir -p "$WORK_DIR" "$OUT_PPTX_DIR" "$OUT_PDF_DIR"
  mkdir -p "$(dirname "$MANIFEST_PATH")"
  if [ ! -f "$MANIFEST_PATH" ]; then
    printf 'timestamp_utc,transcript_relpath,deck_name,status,pptx_path,pdf_path,message\n' > "$MANIFEST_PATH"
  fi
}

append_manifest() {
  # args: transcript_relpath, deck_name, status, pptx_path, pdf_path, message
  # CSV is simple; escape double quotes.
  local ts rel name status pptx pdf msg
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  rel="$1"; name="$2"; status="$3"; pptx="$4"; pdf="$5"; msg="$6"
  msg="${msg//\"/\"\"}"
  printf '%s,"%s","%s","%s","%s","%s","%s"\n' "$ts" "$rel" "$name" "$status" "$pptx" "$pdf" "$msg" >> "$MANIFEST_PATH"
}

clone_or_pull_transcripts() {
  if [ -d "$SRC_REPO_DIR/.git" ]; then
    log "Updating transcripts repo: $SRC_REPO_DIR"
    git -C "$SRC_REPO_DIR" fetch --all --prune
    git -C "$SRC_REPO_DIR" reset --hard origin/HEAD
  else
    log "Cloning transcripts repo into: $SRC_REPO_DIR"
    rm -rf "$SRC_REPO_DIR"
    git clone --depth 1 "$TRANSCRIPT_REPO" "$SRC_REPO_DIR"
  fi

  if [ ! -d "$SRC_TRANSCRIPTS_DIR" ]; then
    err "Transcripts directory not found: $SRC_TRANSCRIPTS_DIR"
    exit 1
  fi
}

check_dependencies() {
  command -v nlm >/dev/null 2>&1 || { err "nlm not found. Install: pip install notebooklm-mcp-cli"; exit 1; }
  command -v soffice >/dev/null 2>&1 || command -v libreoffice >/dev/null 2>&1 || { err "LibreOffice (soffice) not found."; exit 1; }
  command -v git >/dev/null 2>&1 || { err "git not found."; exit 1; }
  command -v python3 >/dev/null 2>&1 || { err "python3 not found."; exit 1; }
}

nlm_login_check() {
  log "Checking NotebookLM login state..."
  if ! nlm login --check >/dev/null 2>&1; then
    err "NotebookLM login missing. Run 'nlm login' on the self-hosted runner once."
    exit 2
  fi
  log "NotebookLM login OK."
}

python_json_get() {
  # Reads JSON from stdin and prints a field expression.
  # usage: python_json_get 'data["id"]'
  local expr="$1"
  python3 -c "import sys, json; data=json.load(sys.stdin); print($expr)"
}

ensure_deckfactory_notebook() {
  log "Ensuring notebook exists (alias: $NLM_NOTEBOOK_ALIAS, name: $NLM_NOTEBOOK_NAME)"
  # If alias exists, this should succeed; otherwise create it.
  if nlm notebook list --json 2>/dev/null | python3 - <<'PY' >/dev/null 2>&1
import sys, json
data=json.load(sys.stdin)
alias="deckfactory"
items=data if isinstance(data, list) else data.get("items") or data.get("notebooks") or []
found=False
for it in items:
  if (it.get("alias") or "") == alias:
    found=True
    break
print("1" if found else "0")
PY
  then
    # Above script returns 0/1 but we didn't capture; do a safer check:
    :
  fi

  # Explicitly determine presence:
  local exists
  exists="$(nlm notebook list --json 2>/dev/null | python3 - <<PY
import sys, json
data=json.load(sys.stdin)
alias="${NLM_NOTEBOOK_ALIAS}"
items=data if isinstance(data, list) else data.get("items") or data.get("notebooks") or []
print("yes" if any((it.get("alias") or "")==alias for it in items) else "no")
PY
)"
  if [ "$exists" = "yes" ]; then
    log "Notebook alias '$NLM_NOTEBOOK_ALIAS' already exists."
    return 0
  fi

  log "Creating notebook '$NLM_NOTEBOOK_NAME' with alias '$NLM_NOTEBOOK_ALIAS'..."
  nlm notebook create --name "$NLM_NOTEBOOK_NAME" --alias "$NLM_NOTEBOOK_ALIAS" --confirm >/dev/null
  log "Notebook created."
}

german_prompt() {
  cat <<'PROMPT'
Erstelle ein Slide-Deck auf Deutsch basierend AUSSCHLIESSLICH auf dem bereitgestellten Transkript.

Vorgaben:
- Sprache: Deutsch
- Umfang: 10–12 Folien
- Zielgruppe: Management / Fachpublikum
- Stil: klar, prägnant, entscheidungsorientiert
- Jede Folie: Titel + 3–5 Bulletpoints, max. 12 Wörter pro Bulletpoint
- Zahlen, Eigennamen und Datumsangaben: exakt übernehmen
- Keine erfundenen Fakten, keine klinischen/realen Details hinzufügen, die nicht im Transkript stehen
- Wenn der Sprecher unklar ist: “Sprecher 1”, “Sprecher 2” verwenden
- Unklarheiten oder Widersprüche explizit markieren als: “Unklar/Widerspruch: …”

Empfohlene Struktur:
1) Titel / Kontext
2) Agenda
3) Leitsymptome / Verlauf (falls vorhanden)
4) Kernthemen (2–4 Folien)
5) Entscheidungen / Beschlüsse
6) Risiken / offene Fragen
7) Empfehlungen
8) Nächste Schritte (Checkliste)

Letzte Folie: “Nächste Schritte” als Checkliste mit:
- To-do
- Owner/Rolle
- Deadline (wenn nicht im Transkript: “TBD”)
PROMPT
}

safe_filename() {
  # Keep original base name; ensure no path traversal.
  # args: path -> prints basename without extension
  local p="$1"
  local b
  b="$(basename "$p")"
  printf '%s' "${b%.txt}"
}

pptx_to_pdf() {
  # args: input_pptx output_pdf_dir
  local input_pptx="$1"
  local out_dir="$2"
  mkdir -p "$out_dir"

  # LibreOffice writes PDF into out_dir with same base name.
  # Use a temp profile to avoid locking issues.
  local tmp_profile
  tmp_profile="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_profile'" RETURN

  if soffice --headless --nologo --nodefault --nofirststartwizard \
    -env:UserInstallation="file://${tmp_profile}" \
    --convert-to pdf --outdir "$out_dir" "$input_pptx" >/dev/null 2>&1; then
    return 0
  fi

  # Fallback: some systems use libreoffice binary name.
  if command -v libreoffice >/dev/null 2>&1; then
    if libreoffice --headless --nologo --nodefault --nofirststartwizard \
      -env:UserInstallation="file://${tmp_profile}" \
      --convert-to pdf --outdir "$out_dir" "$input_pptx" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

process_one() {
  # args: txt_path
  local txt_path="$1"
  local deck_name
  deck_name="$(safe_filename "$txt_path")"

  local pptx_path="${OUT_PPTX_DIR}/${deck_name}.pptx"
  local pdf_path="${OUT_PDF_DIR}/${deck_name}.pdf"

  local rel
  rel="${txt_path#${SRC_REPO_DIR}/}"

  if [ -f "$pptx_path" ] && [ -f "$pdf_path" ]; then
    log "SKIP (already exists): $deck_name"
    append_manifest "$rel" "$deck_name" "skipped" "$pptx_path" "$pdf_path" "already exists"
    return 0
  fi

  log "Processing: $deck_name"
  local source_id=""
  local ok="false"
  local msg=""

  # Always best-effort cleanup source if we managed to create it.
  cleanup() {
    if [ -n "${source_id}" ]; then
      log "Cleanup: deleting source ${source_id}"
      nlm source delete "$source_id" "$NLM_NOTEBOOK_ALIAS" --confirm >/dev/null 2>&1 || true
    fi
  }
  trap cleanup RETURN

  # a) source add
  log "Adding source to notebook..."
  # Expect JSON output with an id; tolerate different shapes.
  if ! source_id="$(
    nlm source add "$NLM_NOTEBOOK_ALIAS" --file "$txt_path" --wait --json 2>/dev/null \
      | python3 - <<'PY'
import sys, json
data=json.load(sys.stdin)
# Try common patterns
for key in ("source_id","id"):
  if isinstance(data, dict) and key in data:
    print(data[key]); sys.exit(0)
# Maybe nested
if isinstance(data, dict):
  for k in ("source","item","data","result"):
    v=data.get(k)
    if isinstance(v, dict):
      for key in ("source_id","id"):
        if key in v:
          print(v[key]); sys.exit(0)
print("")
PY
  )"; then
    msg="source add failed"
    err "$msg: $deck_name"
    append_manifest "$rel" "$deck_name" "fail" "$pptx_path" "$pdf_path" "$msg"
    return 0
  fi

  if [ -z "$source_id" ]; then
    msg="source id parse failed"
    err "$msg: $deck_name"
    append_manifest "$rel" "$deck_name" "fail" "$pptx_path" "$pdf_path" "$msg"
    return 0
  fi

  log "Source added. source_id=$source_id"

  # b) create slide deck
  log "Creating slide deck in Studio..."
  local prompt
  prompt="$(german_prompt)"
  if ! nlm studio create "$NLM_NOTEBOOK_ALIAS" --type slide-deck --prompt "$prompt" --confirm >/dev/null 2>&1; then
    msg="studio create failed"
    err "$msg: $deck_name"
    append_manifest "$rel" "$deck_name" "fail" "$pptx_path" "$pdf_path" "$msg"
    return 0
  fi

  # c) download pptx
  log "Downloading PPTX..."
  mkdir -p "$OUT_PPTX_DIR"
  if ! nlm download slide-deck "$NLM_NOTEBOOK_ALIAS" --format pptx --output "$pptx_path" >/dev/null 2>&1; then
    msg="pptx download failed"
    err "$msg: $deck_name"
    append_manifest "$rel" "$deck_name" "fail" "$pptx_path" "$pdf_path" "$msg"
    return 0
  fi

  # d) pptx -> pdf
  log "Converting PPTX to PDF..."
  mkdir -p "$OUT_PDF_DIR"
  if pptx_to_pdf "$pptx_path" "$OUT_PDF_DIR"; then
    if [ ! -f "$pdf_path" ]; then
      # LibreOffice should create it; if not, treat as failure but keep pptx.
      msg="pdf convert produced no output"
      warn "$msg: $deck_name"
      append_manifest "$rel" "$deck_name" "partial" "$pptx_path" "$pdf_path" "$msg"
      ok="true"
      return 0
    fi
  else
    msg="pdf conversion failed (pptx kept)"
    warn "$msg: $deck_name"
    append_manifest "$rel" "$deck_name" "partial" "$pptx_path" "$pdf_path" "$msg"
    ok="true"
    return 0
  fi

  ok="true"
  append_manifest "$rel" "$deck_name" "success" "$pptx_path" "$pdf_path" "ok"
  log "DONE: $deck_name"
  return 0
}

main() {
  check_dependencies
  ensure_dirs
  clone_or_pull_transcripts
  nlm_login_check
  ensure_deckfactory_notebook

  log "Scanning for TXT transcripts..."
  # Find only *.txt (no SRT); stable order.
  # shellcheck disable=SC2016
  mapfile -t files < <(find "$SRC_TRANSCRIPTS_DIR" -type f -name '*.txt' -print | LC_ALL=C sort)

  if [ "${#files[@]}" -eq 0 ]; then
    log "No .txt files found under: $SRC_TRANSCRIPTS_DIR"
    exit 0
  fi

  log "Found ${#files[@]} transcript(s). MAX_PER_RUN=$MAX_PER_RUN"
  local count=0

  for f in "${files[@]}"; do
    if [ "$count" -ge "$MAX_PER_RUN" ]; then
      log "Reached MAX_PER_RUN=$MAX_PER_RUN. Exiting."
      break
    fi

    # Skip if already built (idempotent)
    local name pptx_path pdf_path
    name="$(safe_filename "$f")"
    pptx_path="${OUT_PPTX_DIR}/${name}.pptx"
    pdf_path="${OUT_PDF_DIR}/${name}.pdf"
    if [ -f "$pptx_path" ] && [ -f "$pdf_path" ]; then
      log "SKIP (already exists): $name"
      append_manifest "${f#${SRC_REPO_DIR}/}" "$name" "skipped" "$pptx_path" "$pdf_path" "already exists"
      continue
    fi

    process_one "$f" || true
    count=$((count + 1))
  done

  log "Run complete. Processed (attempted) $count transcript(s)."
  log "Outputs: $OUT_PPTX_DIR/, $OUT_PDF_DIR/"
  log "Manifest: $MANIFEST_PATH"
}

main "$@"
