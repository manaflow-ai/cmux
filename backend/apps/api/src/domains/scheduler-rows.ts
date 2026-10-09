import { createHash } from "node:crypto"
import { canonicalJson, type RowReader, type StoredRow } from "@cmux/ownership"
import type { Automation, Body, Run, RunState } from "@cmux/protocol"
import type { RunRecord, SchedulerState } from "./scheduler.ts"

/**
 * SchedulerDO automations, runs and bodies live in rows ((g1), DO audit F-1), so the JSON head
 * stays small with 100 automations of 20,000-character instructions and 450 kept runs. This is
 * the one lookup module: every reader of an automation, a run or a body goes through it.
 *
 * - `automation/<id>`: the automation without its body, plus `body_hash`; n = creation order.
 * - `run/<id>`: the run without its body, plus `body_hash`; n = creation order.
 * - `body/<sha256 hex of the canonical JSON>`: `{ body, refs }`, refs = automations plus kept runs
 *   that point at it, adjusted in the same commit; the row goes when refs reaches 0.
 * - `finished/<run id>`: the index of finished runs (n = the run's creation order), so prune takes
 *   the oldest finished runs without reading the open ones.
 *
 * All four tables are private: events and snapshots carry only the head.
 */
export const TABLE_AUTOMATION = "automation"
export const TABLE_RUN = "run"
export const TABLE_BODY = "body"
export const TABLE_FINISHED = "finished"
export const SCHEDULER_PRIVATE_TABLES: ReadonlyArray<string> = [TABLE_AUTOMATION, TABLE_RUN, TABLE_BODY, TABLE_FINISHED]

export type AutomationRow = Omit<Automation, "body"> & { readonly body_hash: string }
export type RunRow = Omit<RunRecord, "body"> & { readonly body_hash: string }
export interface BodyRow {
  readonly body: Body
  readonly refs: number
}

/** Content address of a body: sha256 (hex) of its canonical JSON. */
export const bodyHash = (body: Body): string => createHash("sha256").update(canonicalJson(body)).digest("hex")

/** True for a head from before (g1) that still holds the maps (until scheduler.rows_migrate). */
export const isLegacyHead = (s: Pick<SchedulerState, "automations" | "runs">): boolean => s.automations !== undefined || s.runs !== undefined

export const bodyOf = (rows: RowReader | undefined, hash: string): Body | undefined => rows?.get<BodyRow>(TABLE_BODY, hash)?.row.body

const requireBody = (rows: RowReader | undefined, hash: string, owner: string): Body => {
  const body = bodyOf(rows, hash)
  // A missing body row is a broken invariant (refs count every reference); fail loudly, never run a wrong body.
  if (body === undefined) throw new Error(`scheduler: body ${hash} of ${owner} is missing`)
  return body
}

export const automationRowOf = (rows: RowReader | undefined, id: string): AutomationRow | undefined => rows?.get<AutomationRow>(TABLE_AUTOMATION, id)?.row

/** The automation with its body joined. */
export const automationOf = (rows: RowReader | undefined, id: string): Automation | undefined => {
  const row = automationRowOf(rows, id)
  return row ? joinAutomation(rows, row) : undefined
}

export const joinAutomation = (rows: RowReader | undefined, row: AutomationRow): Automation => {
  const { body_hash, ...rest } = row
  return { ...rest, body: requireBody(rows, body_hash, row.id) }
}

export const runRowOf = (rows: RowReader | undefined, id: string): RunRow | undefined => rows?.get<RunRow>(TABLE_RUN, id)?.row

/** The run with the body of the version that fired. */
export const runOf = (rows: RowReader | undefined, id: string): RunRecord | undefined => {
  const row = runRowOf(rows, id)
  if (!row) return undefined
  const { body_hash, ...rest } = row
  return { ...rest, body: requireBody(rows, body_hash, row.id) }
}

/** The body of a run (for dispatch and run limits), read only when needed. */
export const runBody = (rows: RowReader | undefined, run: RunRow): Body => requireBody(rows, run.body_hash, run.id)

/** Every row of an ordered table, in creation order (bounded: 100 automations, about 700 kept runs). */
const allOrdered = <T>(rows: RowReader | undefined, table: string): Array<StoredRow<T>> => {
  if (!rows) return []
  const out: Array<StoredRow<T>> = []
  let after: number | undefined
  for (;;) {
    const page = rows.range<T>(table, { ...(after === undefined ? {} : { after }), limit: 1000 })
    out.push(...page)
    if (page.length < 1000) return out
    after = page.at(-1)!.n!
  }
}

/** Every automation (without bodies), oldest first. At most MAX_AUTOMATIONS. */
export const allAutomations = (rows: RowReader | undefined): Array<AutomationRow> => allOrdered<AutomationRow>(rows, TABLE_AUTOMATION).map((r) => r.row)

/** Every kept run (without bodies), oldest first. */
export const keptRuns = (rows: RowReader | undefined): Array<RunRow> => allOrdered<RunRow>(rows, TABLE_RUN).map((r) => r.row)

/** The open (not terminal) runs, by the head's id list (at most MAX_OPEN_RUNS_PER_TEAM). */
export const openRuns = (s: Pick<SchedulerState, "open_runs">, rows: RowReader | undefined): Array<RunRow> =>
  (s.open_runs ?? []).flatMap((id) => {
    const r = runRowOf(rows, id)
    return r ? [r] : []
  })

/** The public shape of a run (no dispatch fields, no body). */
export const publicRun = (r: RunRecord | RunRow): Run => {
  const { dispatched: _d, deadline_at: _dl, wall_clock_seconds: _w, ...run } = r as RunRecord & { body_hash?: string }
  const { body: _b, body_hash: _h, ...pub } = run as typeof run & { body_hash?: string }
  return pub
}

export const cursorOf = (raw: unknown): number | undefined => {
  if (typeof raw !== "string" || !/^[0-9]{1,15}$/.test(raw)) return undefined
  return Number(raw)
}

/** One page of automations in creation order (keyset on the row order); bodies joined. */
export const listAutomations = (rows: RowReader | undefined, after: number | undefined, limit: number): { items: Array<Automation>; next: string | null } => {
  if (!rows) return { items: [], next: null }
  const page = rows.range<AutomationRow>(TABLE_AUTOMATION, { ...(after === undefined ? {} : { after }), limit: limit + 1 })
  const items = page.slice(0, limit)
  return { items: items.map((r) => joinAutomation(rows, r.row)), next: page.length > limit ? String(items.at(-1)!.n) : null }
}

/**
 * One page of runs, newest first (keyset on creation order, so new runs never shift later pages),
 * optionally of one automation and one state. Scans the kept runs in steps (at most about 700).
 */
export const listRuns = (
  rows: RowReader | undefined,
  q: { readonly automation?: string; readonly state?: RunState; readonly before?: number; readonly limit: number }
): { items: Array<RunRow>; next: string | null } => {
  if (!rows) return { items: [], next: null }
  const items: Array<StoredRow<RunRow>> = []
  let before = q.before
  for (;;) {
    const page = rows.range<RunRow>(TABLE_RUN, { ...(before === undefined ? {} : { before }), limit: 200, desc: true })
    for (const r of page) {
      if ((q.automation === undefined || r.row.automation === q.automation) && (q.state === undefined || r.row.state === q.state)) items.push(r)
      if (items.length === q.limit) return { items: items.map((x) => x.row), next: String(r.n) }
    }
    if (page.length < 200) return { items: items.map((x) => x.row), next: null }
    before = page.at(-1)!.n!
  }
}
