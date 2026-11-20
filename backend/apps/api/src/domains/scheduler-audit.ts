import type { Principal, RowReader, RowWrite } from "@cmux/ownership"
import type { SchedulerState } from "./scheduler.ts"

/**
 * The SchedulerDO's audit log (docs/automations-teleport-teams.md section 4): one private row per
 * change a person, install or agent made (create, update, pause, delete, run now, deploy, move),
 * written in the same commit as the change. An entry names who, which op, which automation and a
 * short summary; never a body, a prompt or a secret. The oldest entries go past MAX_AUDIT.
 */
export { TABLE_AUDIT_LOG as TABLE_AUDIT } from "./scheduler-rows.ts"
import { TABLE_AUDIT_LOG as TABLE_AUDIT } from "./scheduler-rows.ts"
export const MAX_AUDIT = 2000

export interface AuditRow {
  readonly at: number
  readonly actor: string
  readonly op: string
  readonly automation: string
  readonly summary: string
}

export const AUDITED_OPS: ReadonlySet<string> = new Set([
  "automation.create",
  "automation.update",
  "automation.delete",
  "automation.deploy",
  "automation.run",
  "automation.import",
  "automation.teleport.begin",
  "automation.teleport.complete",
  "automation.teleport.abort"
])

/** Who did it: the user, else the install or agent identity. */
export const actorOf = (p: Principal): string => p.user ?? p.identity

/** Fields an update names, never their values (a name or prompt could be private). */
const changed = (params: Record<string, unknown>) =>
  Object.keys(params)
    .filter((k) => k !== "automation" && k !== "expected_version")
    .sort()

export const summaryOf = (op: string, params: unknown, value: unknown): string => {
  const p = (params ?? {}) as Record<string, unknown>
  const v = (value ?? {}) as Record<string, unknown>
  switch (op) {
    case "automation.create":
      return "created"
    case "automation.update": {
      const keys = changed(p)
      if (keys.length === 1 && keys[0] === "enabled") return p.enabled === false ? "paused" : "resumed"
      return `changed ${keys.join(", ")}`.slice(0, 500)
    }
    case "automation.delete":
      return "deleted"
    case "automation.deploy":
      return `deployed ${String(p.commit ?? "").slice(0, 12)}`
    case "automation.run":
      return "ran now"
    case "automation.import":
      return `moved in from ${String((p.handoff as { from?: unknown } | undefined)?.from ?? "")}`.slice(0, 500)
    case "automation.teleport.begin":
      return `moving to ${String((p.handoff as { to?: unknown } | undefined)?.to ?? "")}`.slice(0, 500)
    case "automation.teleport.complete":
      return `moved to ${String(v.moved_to ?? "")}`.slice(0, 500)
    case "automation.teleport.abort":
      return "move aborted"
    default:
      return op
  }
}

/** The automation an op's answer is about. */
export const automationOfOp = (params: unknown, value: unknown): string | undefined => {
  const p = (params ?? {}) as { automation?: unknown }
  const v = (value ?? {}) as { id?: unknown; automation?: unknown }
  if (typeof p.automation === "string") return p.automation
  if (typeof v.automation === "string") return v.automation
  if (typeof v.id === "string" && v.id.startsWith("auto_")) return v.id
  return undefined
}

/** The writes that append one entry (and drop the oldest past MAX_AUDIT), and the head with the new counters. */
export const appendAudit = <S extends SchedulerState>(state: S, rows: RowReader | undefined, entry: AuditRow): { state: S; writes: Array<RowWrite> } => {
  const n = (state.row_seq ?? 0) + 1
  const writes: Array<RowWrite> = [{ table: TABLE_AUDIT, op: "upsert", key: String(n).padStart(15, "0"), n, row: entry }]
  let count = (state.audit_count ?? 0) + 1
  if (count > MAX_AUDIT && rows) {
    for (const old of rows.range<AuditRow>(TABLE_AUDIT, { limit: count - MAX_AUDIT })) {
      writes.push({ table: TABLE_AUDIT, op: "delete", key: old.key })
      count -= 1
    }
  }
  return { state: { ...state, row_seq: n, audit_count: count }, writes }
}

/** Every entry, oldest first (at most MAX_AUDIT). */
export const allAudit = (rows: RowReader | undefined): Array<AuditRow & { n: number }> => {
  if (!rows) return []
  const out: Array<AuditRow & { n: number }> = []
  let after: number | undefined
  for (;;) {
    const page = rows.range<AuditRow>(TABLE_AUDIT, { ...(after === undefined ? {} : { after }), limit: 1000 })
    for (const r of page) out.push({ ...r.row, n: r.n! })
    if (page.length < 1000) return out
    after = page.at(-1)!.n!
  }
}
