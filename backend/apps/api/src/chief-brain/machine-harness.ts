/** The harnesses a default Chief machine runs (Claude Code or Codex); null and "claude" are Claude. */
export type MachineHarness = "claude" | "codex"
/** The one predicate admission, activation, settings and the default Chief backfill share: null means unsupported. */
export const machineHarness = (harness: string | null): MachineHarness | null => harness === null || harness === "claude" ? "claude" : harness === "codex" ? "codex" : null
