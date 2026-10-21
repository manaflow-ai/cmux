/**
 * The fixed guest commands of the keyed acpmux start on a Cloud machine of the app server
 * (cx-kvmz, cx-0q7o slice 2e; acpmux hub/person.rs). A COPY of the commands of slice 2d
 * (web/services/vms/drivers/acpmuxPersonKey.ts and the cmux-tui layout helpers of
 * web/services/vms/drivers/cmuxTuiDaemon.ts it uses): the Worker cannot import web code.
 * scripts/cmux-next/check-acpmux-guest-commands.ts compares every command this file makes with
 * the web copy byte for byte; change both together.
 *
 * No command here takes anything from the caller: the key K arrives on the stdin of the keyed
 * start only, and a person_holds nonce is checked hex before it is put into a frame. Every command
 * runs as root through the provider exec, then as the session daemon's own user, home and
 * environment, so the acpmux it starts uses the socket the session daemon's agent-session-* verbs use.
 */

/** Exit status of a command that refuses a team machine (the agent-session-start team_vm_blocked rule). */
export const ACPMUX_EXIT_TEAM_VM = 81
/** Exit status of a prepare on a machine whose cmux-tui has no keyed start. */
export const ACPMUX_EXIT_UNSUPPORTED = 82
/**
 * The guest kills a keyed start or a person_holds check after this long: under the provider's 5 s
 * background window, so the call that carries the key is never one the provider stores (the
 * driver also sends no background header); a start that needs longer fails as a timeout.
 */
export const ACPMUX_STDIN_EXEC_TIMEOUT_MS = 4_500
/** The shutdown with agent handoff of the prepare step (no stdin). */
export const ACPMUX_PREPARE_TIMEOUT_MS = 75_000

export const shellQuote = (value: string): string => `'${value.replace(/'/g, `'\\''`)}'`

const WORK_USER = "cmux"
const WORK_HOME = `/home/${WORK_USER}`
const LEGACY_HOME = "/root"
const DAEMON_TERMINAL_ENV = 'TERM=xterm-256color TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION="$(cat /etc/cmux/ghostty-version 2>/dev/null)"'

/** CMUX_TUI_USER, _HOME, _BIN and _LAYOUT of the layout this machine serves (web cmuxTuiLayoutSelector). */
export const layoutSelector = (): string =>
  `if id -u ${WORK_USER} >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1 && ` +
  `setpriv --reuid=${WORK_USER} --regid=${WORK_USER} --init-groups test -w ${WORK_HOME} 2>/dev/null && ` +
  `setpriv --reuid=${WORK_USER} --regid=${WORK_USER} --init-groups sudo -n true >/dev/null 2>&1; then ` +
  `CMUX_TUI_USER=${WORK_USER}; CMUX_TUI_HOME=${WORK_HOME}; CMUX_TUI_LAYOUT=user; ` +
  `else CMUX_TUI_USER=root; CMUX_TUI_HOME=${LEGACY_HOME}; CMUX_TUI_LAYOUT=root; fi; ` +
  `CMUX_TUI_BIN="$CMUX_TUI_HOME/.cmux/bin/cmux-tui"`

/** `command` as the daemon's user through setpriv (web cmuxTuiAsDaemonUser). */
export const asDaemonUser = (command: string, options?: { readonly exec?: boolean }): string => {
  const run = options?.exec === true ? "exec " : ""
  return (
    `if [ "$CMUX_TUI_USER" = root ]; then ${run}env HOME="$CMUX_TUI_HOME" ${DAEMON_TERMINAL_ENV} ${command}; ` +
    `else ${run}setpriv --reuid="$CMUX_TUI_USER" --regid="$CMUX_TUI_USER" --init-groups ` +
    `env HOME="$CMUX_TUI_HOME" USER="$CMUX_TUI_USER" LOGNAME="$CMUX_TUI_USER" SHELL=/bin/bash ${DAEMON_TERMINAL_ENV} ${command}; fi`
  )
}

const HOST_UNITS = ["cmux-host.service", "cmux-tui-daemon.service"] as const

/** A team machine refuses (kind `team` in /etc/cmux/vm-kind, or the team files root /srv/team). Root-owned. */
const teamMachineCheck = (): string =>
  `cmux_kind="$(head -c 64 /etc/cmux/vm-kind 2>/dev/null | tr -d '[:space:]')"; ` +
  `if [ "$cmux_kind" = team ] || [ -e /srv/team ]; then echo "cmux: this is a team machine" >&2; exit ${ACPMUX_EXIT_TEAM_VM}; fi`

/** Session daemon variables a detached acpmux must not take (terminal identity, systemd's, and the ones the start sets). */
const DROPPED_ENV = [
  "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID", "CMUX_PANE_ID",
  "INVOCATION_ID", "JOURNAL_STREAM", "SYSTEMD_EXEC_PID", "NOTIFY_SOCKET", "MAINPID", "MANAGERPID",
  "LISTEN_FDS", "LISTEN_PID", "LISTEN_FDNAMES", "WATCHDOG_PID", "WATCHDOG_USEC", "OLDPWD", "PWD",
  "HOME", "USER", "LOGNAME", "SHELL", "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"
] as const

/** Layout and team refusal, with stdin closed so nothing here can read the key. */
const setup = (): string => `{ ${layoutSelector()} && ${teamMachineCheck()}; } </dev/null`

/**
 * The keyed start as one FIXED bash script ($1 user, $2 home, $3 binary). The session daemon's
 * environ is only data: read NUL-separated into an array, each entry kept only with a valid name,
 * passed as one argv entry to `env -i`; no value reaches eval, sh -c or an unquoted expansion. The
 * daemon runs in a transient systemd scope of its own with a fixed description (else systemd names
 * the scope by its command line, which holds every kept value, and writes that to the journal).
 * Only the final `exec` has the exec's stdin (the key).
 */
const KEYED_START_SCRIPT = [
  `user=$1 home=$2 bin=$3`,
  `drop=(env)`,
  `if [ "$user" != root ]; then drop=(setpriv "--reuid=$user" "--regid=$user" --init-groups env); fi`,
  `scope=()`,
  `if command -v systemd-run >/dev/null 2>&1; then scope=(systemd-run --scope --quiet --collect "--description=cmux acpmux keyed start" "--unit=cmux-acpmux-keyed-$$-$(date +%s </dev/null)"); fi`,
  `vars=()`,
  `pid=$(pgrep -o -u "$user" -f '[c]mux-tui server start' </dev/null || true)`,
  `if [ -n "$pid" ] && [ -r "/proc/$pid/environ" ]; then`,
  `  while IFS= read -r -d '' kv; do vars+=("$kv"); done < "/proc/$pid/environ"`,
  `else`,
  `  for unit in ${HOST_UNITS.join(" ")}; do`,
  `    line=$(systemctl show -p Environment --value "$unit" </dev/null 2>/dev/null || true)`,
  `    if [ -n "$line" ]; then IFS=' ' read -r -a words <<< "$line"; vars+=("\${words[@]}"); break; fi`,
  `  done`,
  `fi`,
  `keep=()`,
  `for kv in "\${vars[@]}"; do`,
  `  name=\${kv%%=*}`,
  `  [[ "$kv" == *=* && "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue`,
  `  case "$name" in ${DROPPED_ENV.join("|")}) continue ;; esac`,
  `  keep+=("$kv")`,
  `done`,
  `version=$(head -c 64 /etc/cmux/ghostty-version 2>/dev/null </dev/null | tr -cd 'A-Za-z0-9._+-')`,
  `exec "\${scope[@]}" "\${drop[@]}" -i "\${keep[@]}" "HOME=$home" "USER=$user" "LOGNAME=$user" SHELL=/bin/bash ` +
    `TERM=xterm-256color TERM_PROGRAM=ghostty "TERM_PROGRAM_VERSION=$version" "$bin" acp --json daemon start --person-key-fd 0`
].join("\n")

/**
 * Step 1, no stdin: refuse a cmux-tui without `--person-key-fd` BEFORE the running daemon stops,
 * then stop it and hand its agents to the next run (no daemon running is not an error).
 */
export const acpmuxPrepareCommand = (): string => {
  const help = asDaemonUser(`"$CMUX_TUI_BIN" acp daemon start --help`)
  const shutdown = asDaemonUser(`"$CMUX_TUI_BIN" acp daemon shutdown --keep-agents`)
  return [
    setup(),
    `{ ${help}; } </dev/null 2>&1 | grep -q -e '--person-key-fd' || { echo "cmux: this machine's cmux-tui has no keyed start" >&2; exit ${ACPMUX_EXIT_UNSUPPORTED}; }`,
    `{ ${shutdown}; } </dev/null >/dev/null 2>&1 || true`,
    "echo prepared"
  ].join(" && ")
}

/** Step 2, stdin = K (64 lowercase hex and a newline): prints acpmux's status JSON (`personKey`, `personInstance`). */
export const acpmuxKeyedStartCommand = (): string =>
  `${setup()} && { command -v bash >/dev/null 2>&1 </dev/null || { echo "cmux: this machine has no bash" >&2; exit ${ACPMUX_EXIT_UNSUPPORTED}; }; } && ` +
  `exec bash -c ${shellQuote(KEYED_START_SCRIPT)} cmux-acpmux-keyed-start "$CMUX_TUI_USER" "$CMUX_TUI_HOME" "$CMUX_TUI_BIN"`

/** `_acpmux/person_holds` over `acp stdio`; stdin = {@link acpmuxPersonHoldsFrames}. */
export const acpmuxPersonHoldsCommand = (): string => `${setup()} && ${asDaemonUser(`"$CMUX_TUI_BIN" acp stdio`, { exec: true })}`

const HEX64 = /^[0-9a-f]{64}$/

/** Whether `nonce` is a person_holds nonce (64 lowercase hex characters). */
export const isAcpmuxNonce = (nonce: unknown): nonce is string => typeof nonce === "string" && HEX64.test(nonce)

/** The frames of the person_holds check (as SSHService+PersonKey.swift sends them). */
export const acpmuxPersonHoldsFrames = (nonce: string): string => {
  if (!isAcpmuxNonce(nonce)) throw new Error("acpmux person_holds nonce must be 64 lowercase hex characters")
  return [
    JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } }),
    JSON.stringify({ jsonrpc: "2.0", id: 2, method: "_acpmux/person_holds", params: { nonce } }),
    ""
  ].join("\n")
}

/** Whether `bytes` is one person key line: 64 lowercase hex characters and a newline. */
export const isAcpmuxKeyLine = (bytes: Uint8Array): boolean => {
  if (bytes.byteLength !== 65 || bytes[64] !== 0x0a) return false
  for (let i = 0; i < 64; i += 1) {
    const b = bytes[i]!
    if (!((b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66))) return false
  }
  return true
}

/** Text that came back from the guest, with every 64-hex run removed and bounded. */
export const redactGuestLine = (text: string): string | undefined => {
  const line = text.split("\n").map((l) => l.trim()).filter(Boolean).at(-1)
  if (!line) return undefined
  return line.replace(/[0-9a-fA-F]{64,}/g, "[redacted]").replace(/[A-Za-z0-9+/]{80,}={0,2}/g, "[redacted]").slice(0, 300)
}
