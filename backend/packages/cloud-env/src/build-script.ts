import type { EnvironmentSpec } from "./spec.ts"

/**
 * The guest half of an environment build: one bash script, run once as the work user on a builder
 * machine booted from the base image, right before the snapshot. A snapshot boot never runs it.
 * It never writes a secret value: secret variables are only named in the marker; their values reach
 * a workspace at boot from the vault (design §4).
 */

/** Where the build records what the snapshot holds, relative to the work home. */
export const ENVIRONMENT_MARKER_PATH = ".cmux/environment.json"
/** The profile script every login shell sources for the plain variables. */
export const ENVIRONMENT_PROFILE_FILE = "cmux-environment.sh"

const FULL_SHA = /^[0-9a-f]{40}$/

export const shellQuote = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`
const printfLine = (line: string) => `printf '%s\\n' ${shellQuote(line)}`

/** The checkout directory under the work home, or null without a repo. */
export const environmentCheckoutPath = (spec: EnvironmentSpec): string | null => (spec.repo ? `work/${spec.repo.name}` : null)

const cloneLines = (spec: EnvironmentSpec): Array<string> => {
  if (!spec.repo) return ['cd "$HOME/work"']
  const url = `https://github.com/${spec.repo.owner}/${spec.repo.name}.git`
  const ref = spec.repo.ref
  const lines = [`dest="$HOME/work/"${shellQuote(spec.repo.name)}`, 'if [ ! -d "$dest/.git" ]; then']
  if (ref && FULL_SHA.test(ref)) {
    lines.push('  git init -q "$dest"', `  git -C "$dest" remote add origin ${shellQuote(url)}`, `  git -C "$dest" fetch -q --depth 1 origin ${shellQuote(ref)}`, '  git -C "$dest" checkout -q --detach FETCH_HEAD')
  } else {
    lines.push(`  git clone -q --depth 1 ${ref ? `--branch ${shellQuote(ref)} ` : ""}${shellQuote(url)} "$dest"`)
  }
  lines.push("fi", 'cd "$dest"')
  return lines
}

/**
 * The script that turns a fresh base-image machine into the environment. Test seams (unset on a
 * machine): CMUX_ENVIRONMENT_HOME (default: the user's passwd home; a provider exec can carry a
 * stale HOME), CMUX_ENVIRONMENT_SUDO (default `sudo`), CMUX_ENVIRONMENT_PROFILE_DIR (default
 * /etc/profile.d).
 */
export const environmentBuildCommand = (spec: EnvironmentSpec, digest: string): string => {
  const plain = spec.env.filter((v): v is { name: string; value: string } => "value" in v)
  const secrets = spec.env.filter((v) => "secret" in v).map((v) => v.name).sort()
  const lines = [
    "set -euo pipefail",
    'export HOME="${CMUX_ENVIRONMENT_HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"',
    'sudo_cmd="${CMUX_ENVIRONMENT_SUDO-sudo}"',
    'profile_dir="${CMUX_ENVIRONMENT_PROFILE_DIR:-/etc/profile.d}"',
    'mkdir -p "$HOME/work" "$HOME/.cmux"',
    'env_file="$HOME/.cmux/environment.env"',
    ': > "$env_file"',
    ...plain.map((v) => `${printfLine(`export ${v.name}=${shellQuote(v.value)}`)} >> "$env_file"`),
    '$sudo_cmd mkdir -p "$profile_dir"',
    `$sudo_cmd install -m 0644 "$env_file" "$profile_dir/${ENVIRONMENT_PROFILE_FILE}"`,
    'set -a; . "$env_file"; set +a',
    ...cloneLines(spec)
  ]
  if (spec.setupScript.trim()) lines.push('setup="$HOME/.cmux/environment-setup.sh"', `${printfLine(spec.setupScript)} > "$setup"`, 'bash -e "$setup"')
  lines.push(`${printfLine(JSON.stringify({ digest, secrets }))} > "$HOME/${ENVIRONMENT_MARKER_PATH}"`, "sync")
  return lines.join("\n") + "\n"
}

/** The one exec a sandbox runs: the script as an argument to bash, its stderr folded into stdout. */
export const environmentBuildExec = (spec: EnvironmentSpec, digest: string): string => `bash -c ${shellQuote(environmentBuildCommand(spec, digest))} 2>&1`

/** Where a detached build writes its log and, when it ends, its exit code (relative to the work home). */
export const ENVIRONMENT_BUILD_LOG = ".cmux/environment-build.log"
export const ENVIRONMENT_BUILD_EXIT = ".cmux/environment-build.exit"

const HOME_LINE = 'h="$(getent passwd "$(id -un)" | cut -d: -f6)"; h="${CMUX_ENVIRONMENT_HOME:-$h}"'

/**
 * Starts the build detached and returns at once: a provider exec has a hard timeout (about five
 * minutes on Freestyle), and a real setup (a clone plus an install) can take longer. The exit code
 * lands in ENVIRONMENT_BUILD_EXIT when the script ends; `environmentBuildPollExec` reads it.
 */
export const environmentBuildStartExec = (spec: EnvironmentSpec, digest: string): string =>
  [
    HOME_LINE,
    'mkdir -p "$h/.cmux"',
    `rm -f "$h/${ENVIRONMENT_BUILD_EXIT}"`,
    `nohup bash -c ${shellQuote(`bash -c ${shellQuote(environmentBuildCommand(spec, digest))}; echo $? > "$0"`)} "$h/${ENVIRONMENT_BUILD_EXIT}" > "$h/${ENVIRONMENT_BUILD_LOG}" 2>&1 < /dev/null &`,
    "echo started"
  ].join("\n")

/** Prints `exit <code>` when the detached build ended, `running` before; then the log tail. */
export const environmentBuildPollExec = (): string =>
  [
    HOME_LINE,
    `if [ -f "$h/${ENVIRONMENT_BUILD_EXIT}" ]; then echo "exit $(cat "$h/${ENVIRONMENT_BUILD_EXIT}")"; else echo running; fi`,
    `tail -c 4096 "$h/${ENVIRONMENT_BUILD_LOG}" 2>/dev/null || true`
  ].join("\n")

/** The poll answer: the exit code once the build ended (null while it runs) and the log tail. */
export const parseBuildPoll = (stdout: string): { readonly exitCode: number | null; readonly log: string } => {
  const nl = stdout.indexOf("\n")
  const head = (nl === -1 ? stdout : stdout.slice(0, nl)).trim()
  const log = nl === -1 ? "" : stdout.slice(nl + 1)
  const m = head.match(/^exit (\d+)$/)
  return { exitCode: m ? Number(m[1]) : null, log }
}
