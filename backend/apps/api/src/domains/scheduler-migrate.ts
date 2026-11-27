import type { ReduceResult, RowReader, RowWrite } from "@cmux/ownership"
import type { Body } from "@cmux/protocol"
import {
  bodyHash,
  bodyOf,
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
 * commit. Rows already there (a head that was refilled with maps after an earlier migration) are
 * merged, never dropped: the maps win per id, and a row whose id the maps lack stays with its
 * body. All rows are then rewritten in creation order and every body's reference count is
 * recounted, so counts never double. A kept row whose body row is missing breaks the invariant
 * and cannot run; it is dropped. Bounded by the map and row sizes (100 automations, the open runs
 * plus the newest 200 finished). A head without maps is a no-op, so the op is idempotent on a live
 * object. (A deletion that only the maps saw cannot be told from a row the maps never knew, so a
 * merge may bring such a record back; losing rows created after the first migration is worse.)
 */
export const reduceRowsMigrate = (state: SchedulerState, rows: RowReader | undefined): ReduceResult<SchedulerState> => {
  if (!isLegacyHead(state)) return { ok: true, state, value: null, changed: false }
  const { automations: legacyAutomations, runs: legacyRuns, ...rest } = state

  // Every existing row is rewritten below (its order may change), with the bodies it points at.
  const deletes: Array<RowWrite> = []
  const existingBodies = new Set<string>()
  const keptAutomations = new Map<string, AutomationRow>()
  const keptRuns = new Map<string, RunRow>()
  for (const table of [TABLE_AUTOMATION, TABLE_RUN, TABLE_FINISHED]) {
    for (const r of keysOf(rows, table)) {
      deletes.push({ table, op: "delete", key: r.key })
      if (table === TABLE_AUTOMATION) keptAutomations.set(r.key, r.row as AutomationRow)
      if (table === TABLE_RUN) keptRuns.set(r.key, r.row as RunRow)
      const hash = (r.row as { body_hash?: unknown }).body_hash
      if (typeof hash === "string") existingBodies.add(hash)
    }
  }

  // The maps win per id; a kept row joins its stored body, or is dropped when that body is gone.
  const withBody = <T extends { readonly id: string; readonly body_hash: string }>(row: T): (Omit<T, "body_hash"> & { body: Body }) | undefined => {
    const body = bodyOf(rows, row.body_hash)
    if (body === undefined) return undefined
    const { body_hash: _h, ...rest } = row
    return { ...rest, body }
  }
  const merged = <R extends { readonly id: string; readonly created_at: number; readonly body: Body }, K extends { readonly id: string; readonly body_hash: string }>(
    fromMaps: Record<string, R> | undefined,
    kept: Map<string, K>
  ): Array<R> => {
    const out = new Map<string, R>(Object.entries(fromMaps ?? {}))
    for (const [id, row] of kept) {
      if (out.has(id)) continue
      const joined = withBody(row)
      if (joined) out.set(id, joined as unknown as R)
    }
    return [...out.values()].sort(byCreation)
  }
  const automations = merged(legacyAutomations, keptAutomations)
  const runs = merged(legacyRuns, keptRuns)

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
  for (const hash of existingBodies) if (!bodies.has(hash)) deletes.push({ table: TABLE_BODY, op: "delete", key: hash })
  for (const [hash, b] of bodies) upserts.push({ table: TABLE_BODY, op: "upsert", key: hash, n: null, row: b })

  return {
    ok: true,
    state: { ...rest, automation_count: automations.length, open_runs: open, finished_count: finished, row_seq: seq },
    writes: [...deletes, ...upserts],
    value: { automations: automations.length, runs: runs.length, bodies: bodies.size }
  }
}
