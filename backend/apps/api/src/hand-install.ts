import type { Env } from "./env.ts"

/**
 * `GET /hand/install.sh`: the hand installer. It detects the OS and CPU, downloads the published
 * acpmux file of the configured cmux-tui commit, checks its SHA-256 against the hash this Worker
 * read from that commit's manifest.json (so a changed file on the download host fails the check),
 * installs it as `~/.cmux-hand/bin/cmux-hand`, runs `cmux-hand hand pair <code>`, and starts a user
 * service (launchd on macOS; systemd --user, else nohup, on Linux). No root, no inbound port.
 *
 *   curl -fsSL <api>/hand/install.sh | sh -s -- --pair <code> [--profile sandbox|mac] [--root DIR]...
 *        [--agent-policy P] [--name N] [--binary PATH (a local file, for development)] [--no-service]
 */

const TARGETS = ["aarch64-apple-darwin", "x86_64-apple-darwin", "x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl"] as const
const DEFAULT_BASE = "https://files.cmux.com/cmux-tui"

const releaseHashes = async (env: Env): Promise<{ base: string; hashes: Record<string, string> } | null> => {
  const commit = env.HAND_RELEASE_COMMIT ?? ""
  const base = (env.HAND_RELEASE_BASE ?? DEFAULT_BASE).replace(/\/$/, "")
  if (!/^[0-9a-f]{40}$/.test(commit) || !/^https:\/\/[A-Za-z0-9.-]+(\/[A-Za-z0-9._/-]*)?$/.test(base)) return null
  const res = await fetch(`${base}/${commit}/manifest.json`, { cf: { cacheTtl: 300 } } as RequestInit).catch(() => null)
  if (!res?.ok) return null
  const manifest = (await res.json().catch(() => null)) as { binaries?: Record<string, string> } | null
  const hashes: Record<string, string> = {}
  for (const t of TARGETS) {
    const h = manifest?.binaries?.[`cmux-tui-acpmux-${t}`]
    if (typeof h === "string" && /^[0-9a-f]{64}$/.test(h)) hashes[t] = h
  }
  return { base: `${base}/${commit}`, hashes }
}

export const handInstallScript = async (env: Env, origin: string): Promise<Response> => {
  if (!/^https?:\/\/[A-Za-z0-9.:-]+$/.test(origin)) return new Response("bad origin\n", { status: 500 })
  const release = await releaseHashes(env)
  const table = TARGETS.map((t) => `    ${t}) SHA="${release?.hashes[t] ?? ""}" ;;`).join("\n")
  const script = `#!/bin/sh
# cmux hand installer (served by ${origin}). Installs one file and a user service; no root.
set -eu
API="${origin}"
RELEASE="${release?.base ?? ""}"
PAIR="" PROFILE="sandbox" NAME="" POLICY="" LOCAL_BIN="" SERVICE=1 ROOTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pair) PAIR="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --root) case "$2" in *[!A-Za-z0-9._/-]*) echo "cmux-hand install: --root takes a plain path (letters, digits, . _ / -)" >&2; exit 2 ;; esac; ROOTS="$ROOTS --root $2"; shift 2 ;;
    --agent-policy) POLICY="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --binary) LOCAL_BIN="$2"; shift 2 ;;
    --no-service) SERVICE=0; shift ;;
    *) echo "cmux-hand install: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$PAIR" ] || { echo "cmux-hand install: --pair <code> is required" >&2; exit 2; }
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) TARGET=aarch64-apple-darwin ;;
  Darwin/x86_64) TARGET=x86_64-apple-darwin ;;
  Linux/x86_64|Linux/amd64) TARGET=x86_64-unknown-linux-musl ;;
  Linux/aarch64|Linux/arm64) TARGET=aarch64-unknown-linux-musl ;;
  *) echo "cmux-hand install: unsupported system $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac
case "$TARGET" in
${table}
esac
HOME_DIR="\${CMUX_HAND_HOME:-$HOME/.cmux-hand}"
BIN_DIR="$HOME_DIR/bin"
BIN="$BIN_DIR/cmux-hand"
mkdir -p "$BIN_DIR"
TMP="$BIN_DIR/.cmux-hand.download.$$"
trap 'rm -f "$TMP"' EXIT
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
if [ -n "$LOCAL_BIN" ]; then
  cp "$LOCAL_BIN" "$TMP"
  echo "cmux-hand install: using the local file $LOCAL_BIN (development; no published hash)" >&2
else
  [ -n "$RELEASE" ] && [ -n "$SHA" ] || { echo "cmux-hand install: this server has no published hand for $TARGET" >&2; exit 1; }
  curl -fsSL "$RELEASE/cmux-tui-acpmux-$TARGET" -o "$TMP"
  GOT="$(sha256 "$TMP")"
  [ "$GOT" = "$SHA" ] || { echo "cmux-hand install: SHA-256 mismatch for $TARGET (got $GOT, want $SHA)" >&2; exit 1; }
fi
chmod 755 "$TMP"
# Replace by rename, never by writing over a running binary (macOS kills a rewritten signed file).
mv -f "$TMP" "$BIN"
trap - EXIT
# shellcheck disable=SC2086 # ROOTS holds only plain paths (checked above)
"$BIN" hand pair "$PAIR" --api "$API" --profile "$PROFILE" \${NAME:+--name "$NAME"} \${POLICY:+--agent-policy "$POLICY"} $ROOTS
[ "$SERVICE" = 1 ] || { echo "cmux-hand: installed; run: $BIN hand run"; exit 0; }
LOG="$HOME_DIR/hand.log"
if [ "$(uname -s)" = Darwin ]; then
  PLIST="$HOME/Library/LaunchAgents/dev.cmux.hand.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.cmux.hand</string>
<key>ProgramArguments</key><array><string>$BIN</string><string>hand</string><string>run</string></array>
<key>EnvironmentVariables</key><dict><key>CMUX_HAND_HOME</key><string>$HOME_DIR</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$LOG</string><key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/dev.cmux.hand" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "cmux-hand: running (launchd dev.cmux.hand); log $LOG"
elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/cmux-hand.service" <<UNIT
[Unit]
Description=cmux hand
After=network-online.target
[Service]
Environment=CMUX_HAND_HOME=$HOME_DIR
ExecStart=$BIN hand run
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now cmux-hand.service
  echo "cmux-hand: running (systemd --user cmux-hand.service)"
else
  CMUX_HAND_HOME="$HOME_DIR" nohup "$BIN" hand run >>"$LOG" 2>&1 &
  echo "cmux-hand: running (nohup, pid $!); log $LOG"
fi
`
  return new Response(script, { headers: { "content-type": "text/x-shellscript; charset=utf-8", "cache-control": "no-store" } })
}
