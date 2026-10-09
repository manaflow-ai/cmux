import type { ReduceResult, RowReader, RowWrite } from "@cmux/ownership"
import type { Body } from "@cmux/protocol"
import {
  bodyHash,
  isLegacyHead,
  TABLE_AUTOMATION,
  TABLE_BODY,
  TABLE_FINISHED,
  TABLE_RUN,
  type AutomationRow,
  type BodyRow,
  type RunRow
} from "./scheduler-rows.ts"
import type { SchedulerState } from "./scheduler.ts"

const FINISHED: ReadonlySet<string> = new Set(["succeeded", "failed", "cancelled", "skipped", "dead"])

/** Every key of an ordered table (bounded: 100 automations, about 700 kept runs). */
const keysOf = (rows: RowReader | undefined, table: string): Array<{ key: string; row: unknown }> => {
  if (!rows) return []
  const out: Array<{ key: string; row: unknown }> = []
  let after: number | undefined
  for (;;) {
    const page = rows.range(table, { ...(after === undefined ? {} : { after }), limit: 1000 })
    out.push(...page.map((r) => ({ key: r.key, row: r.row })))
    if (page.length < 1000) return out
    after = page.at(-1)!.n!
  }
}

const byCreation = <T extends { readonly created_at: number; readonly id: string }>(a: T, b: T) => a.created_at - b.created_at || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)

/**
 * System op `scheduler.rows_migrate` ((g1)): an old head's `automations` and `runs` maps become
 * rows, bodies stored once with their reference counts, and the maps leave the head, in one
 * commit. The maps are the truth: rows already there (a head that a rollback build refilled
 * with maps) are rebuilt from them, so counts and references never double. Bounded by the map
 * sizes (100 automations, the open runs plus the newest 200 finished). A head without maps is a
 * no-op, so the op is idempotent on a live object.
 */
export const reduceRowsMigrate = (state: SchedulerState, rows: RowReader | undefined): ReduceResult<SchedulerState> => {
  if (!isLegacyHead(state)) return { ok: true, state, value: null, changed: false }
  const { automations: legacyAutomations, runs: legacyRuns, ...rest } = state
  const automations = Object.values(legacyAutomations ?? {}).sort(byCreation)
  const runs = Object.values(legacyRuns ?? {}).sort(byCreation)

  // Every existing row goes first (its order may be reused below), with the bodies it points at.
  const deletes: Array<RowWrite> = []
  const oldBodies = new Set<string>()
  for (const table of [TABLE_AUTOMATION, TABLE_RUN, TABLE_FINISHED]) {
    for (const r of keysOf(rows, table)) {
      deletes.push({ table, op: "delete", key: r.key })
      const hash = (r.row as { body_hash?: unknown }).body_hash
      if (typeof hash === "string") oldBodies.add(hash)
    }
  }

  const bodies = new Map<string, BodyRow>()
  const refer = (body: Body): string => {
    const hash = bodyHash(body)
    bodies.set(hash, { body, refs: (bodies.get(hash)?.refs ?? 0) + 1 })
    return hash
  }
  const upserts: Array<RowWrite> = []
  let seq = 0
  for (const a of automations) {
    const { body, ...row } = a
    upserts.push({ table: TABLE_AUTOMATION, op: "upsert", key: a.id, n: ++seq, row: { ...row, body_hash: refer(body) } satisfies AutomationRow })
  }
  const open: Array<string> = []
  let finished = 0
  for (const r of runs) {
    const { body, ...row } = r
    const n = ++seq
    upserts.push({ table: TABLE_RUN, op: "upsert", key: r.id, n, row: { ...row, body_hash: refer(body) } satisfies RunRow })
    if (FINISHED.has(r.state)) {
      finished += 1
      upserts.push({ table: TABLE_FINISHED, op: "upsert", key: r.id, n, row: { run: r.id } })
    } else open.push(r.id)
  }
  for (const hash of oldBodies) if (!bodies.has(hash)) deletes.push({ table: TABLE_BODY, op: "delete", key: hash })
  for (const [hash, b] of bodies) upserts.push({ table: TABLE_BODY, op: "upsert", key: hash, n: null, row: b })

  return {
    ok: true,
    state: { ...rest, automation_count: automations.length, open_runs: open, finished_count: finished, row_seq: seq },
    writes: [...deletes, ...upserts],
    value: { automations: automations.length, runs: runs.length, bodies: bodies.size }
  }
}
