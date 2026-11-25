/**
 * How per-automation secrets reach a machine step (AUTOMATIONS-SPEC section 12): never in the command
 * line (the provider and the machine's process list see it), but as the first line of the step's
 * stdin: base64 of NAME=VALUE entries, each ended by a NUL byte. SECRETS_READER, put before the step's
 * body, reads that line and exports each entry (no eval: `export "NAME=VALUE"` takes the value as
 * is), then leaves the rest of stdin to the command. A detached child of the step inherits them.
 */
export const SECRETS_READER =
  `IFS= read -r __cmux_secrets; while IFS= read -r -d '' __cmux_kv; do export "$__cmux_kv"; done < <(printf '%s' "$__cmux_secrets" | base64 -d); unset __cmux_secrets __cmux_kv; `

/** The stdin line for `secrets` (no newline). */
export const secretsLine = (secrets: Readonly<Record<string, string>>): string => {
  const bytes = new TextEncoder().encode(Object.entries(secrets).map(([k, v]) => `${k}=${v}\u0000`).join(""))
  let bin = ""
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(bin)
}

/** Why `value` cannot be a secret, or undefined. */
export const secretValueProblem = (value: string): string | undefined => (value.includes("\u0000") ? "a secret cannot hold a NUL byte" : undefined)
