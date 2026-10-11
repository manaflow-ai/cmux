import { EMPTY_ROWS, OverlayRows, type RowReader, type RowWrite } from "@cmux/ownership"
import type { Automation, Body } from "@cmux/protocol"
import type { RunRecord, SchedulerState } from "./scheduler.ts"
import {
  bodyHash,
  joinAutomation,
  runBody,
  TABLE_AUTOMATION,
  TABLE_BODY,
  TABLE_FINISHED,
  TABLE_RUN,
  type AutomationRow,
  type BodyRow,
  type RunRow
} from "./scheduler-rows.ts"

const FINISHED: ReadonlySet<string> = new Set(["succeeded", "failed", "cancelled", "skipped", "dead"])

/** The head counters the store keeps in step with the rows. */
type Counters = Pick<SchedulerState, "automation_count" | "open_runs" | "finished_count" | "row_seq">

/**
 * One reduction's view of the SchedulerDO rows ((g1)): reads see the committed rows plus this
 * reduction's own writes; writes collect the row changes and keep the head counters (automation
 * count, open run ids, finished count, row order) and the body reference counts in step. Pure:
 * the reducer creates one per op and returns `head()` and `writes()`.
 */
export class SchedulerStore {
  private readonly view: OverlayRows
  private readonly out = new Map<string, RowWrite>()
  private readonly refs = new Map<string, { delta: number; body?: Body }>()
  private automationCount: number
  private open: Array<string>
  private finishedCount: number
  private seq: number

  constructor(
    state: SchedulerState,
    private readonly base: RowReader = EMPTY_ROWS
  ) {
    this.view = new OverlayRows(base)
    this.automationCount = state.automation_count ?? 0
    this.open = [...(state.open_runs ?? [])]
    this.finishedCount = state.finished_count ?? 0
    this.seq = state.row_seq ?? 0
  }

  /** Rows as this reduction sees them (committed plus its own writes). */
  get rows(): RowReader {
    return this.view
  }

  get finished(): number {
    return this.finishedCount
  }

  automation(id: string): AutomationRow | undefined {
    return this.view.get<AutomationRow>(TABLE_AUTOMATION, id)?.row
  }

  /** The automation with its body (a body first written in this reduction included). */
  automationFull(id: string): Automation | undefined {
    const row = this.automation(id)
    if (!row) return undefined
    const pending = this.refs.get(row.body_hash)?.body
    return pending ? { ...joinWithout(row), body: pending } : joinAutomation(this.view, row)
  }

  run(id: string): RunRow | undefined {
    return this.view.get<RunRow>(TABLE_RUN, id)?.row
  }

  /** A run's body (for run limits), from the rows or this reduction's own writes. */
  runBody(r: RunRow): Body {
    return this.refs.get(r.body_hash)?.body ?? runBody(this.view, r)
  }

  /** Open runs in the head's order. */
  openRuns(): Array<RunRow> {
    return this.open.flatMap((id) => {
      const r = this.run(id)
      return r ? [r] : []
    })
  }

  /** Creates or replaces an automation; a new body hash moves one reference from the old body to the new one. */
  putAutomation(a: Automation): AutomationRow {
    const prior = this.view.get<AutomationRow>(TABLE_AUTOMATION, a.id)
    const { body, ...rest } = a
    const row: AutomationRow = { ...rest, body_hash: bodyHash(body) }
    if (!prior) this.automationCount += 1
    if (prior?.row.body_hash !== row.body_hash) {
      if (prior) this.ref(prior.row.body_hash, -1)
      this.ref(row.body_hash, 1, body)
    }
    this.write({ table: TABLE_AUTOMATION, op: "upsert", key: a.id, n: prior?.n ?? this.next(), row })
    return row
  }

  /** Replaces an automation whose body did not change (triggers, schedule). */
  putAutomationRow(row: AutomationRow): void {
    const prior = this.view.get<AutomationRow>(TABLE_AUTOMATION, row.id)
    if (!prior || prior.row.body_hash !== row.body_hash) throw new Error(`scheduler: automation ${row.id} row replaced with another body`)
    this.write({ table: TABLE_AUTOMATION, op: "upsert", key: row.id, n: prior.n, row })
  }

  deleteAutomation(id: string): void {
    const prior = this.automation(id)
    if (!prior) return
    this.automationCount -= 1
    this.ref(prior.body_hash, -1)
    this.write({ table: TABLE_AUTOMATION, op: "delete", key: id })
  }

  /** A new run with the body of the version that fired; it keeps that body hash for its whole life. */
  addRun(r: RunRecord): RunRow {
    const { body, ...rest } = r
    const row: RunRow = { ...rest, body_hash: bodyHash(body) }
    const n = this.next()
    this.ref(row.body_hash, 1, body)
    this.write({ table: TABLE_RUN, op: "upsert", key: r.id, n, row })
    if (FINISHED.has(r.state)) this.markFinished(r.id, n)
    else this.open.push(r.id)
    return row
  }

  /** Replaces a run (never its body); an open run that becomes terminal moves to the finished index. */
  putRun(row: RunRow): void {
    const prior = this.view.get<RunRow>(TABLE_RUN, row.id)
    if (!prior || prior.row.body_hash !== row.body_hash) throw new Error(`scheduler: run ${row.id} changed its body`)
    if (FINISHED.has(prior.row.state) && !FINISHED.has(row.state)) throw new Error(`scheduler: run ${row.id} reopened`)
    this.write({ table: TABLE_RUN, op: "upsert", key: row.id, n: prior.n, row })
    if (!FINISHED.has(prior.row.state) && FINISHED.has(row.state)) {
      this.open = this.open.filter((id) => id !== row.id)
      this.markFinished(row.id, prior.n!)
    }
  }

  /** Deletes the oldest finished runs past `keep` (their body references go with them). */
  pruneFinished(keep: number): void {
    const excess = this.finishedCount - keep
    if (excess <= 0) return
    for (const f of this.view.range<{ run: string }>(TABLE_FINISHED, { limit: excess })) {
      const r = this.run(f.row.run)
      if (r) {
        this.ref(r.body_hash, -1)
        this.write({ table: TABLE_RUN, op: "delete", key: r.id })
      }
      this.write({ table: TABLE_FINISHED, op: "delete", key: f.key })
      this.finishedCount -= 1
    }
  }

  /** The head with the counters this reduction changed. */
  head<S extends SchedulerState>(state: S): S {
    const counters: Counters = { automation_count: this.automationCount, open_runs: this.open, finished_count: this.finishedCount, row_seq: this.seq }
    return { ...state, ...counters }
  }

  /** The row writes, body rows last (a body row goes when no automation and no kept run points at it). */
  writes(): Array<RowWrite> {
    const bodies: Array<RowWrite> = []
    for (const [hash, { delta, body }] of this.refs) {
      if (delta === 0) continue
      const prior = this.base.get<BodyRow>(TABLE_BODY, hash)?.row
      const refs = (prior?.refs ?? 0) + delta
      if (refs < 0) throw new Error(`scheduler: body ${hash} has ${refs} references`)
      if (refs === 0) {
        if (prior) bodies.push({ table: TABLE_BODY, op: "delete", key: hash })
        continue
      }
      const content = prior?.body ?? body
      if (content === undefined) throw new Error(`scheduler: body ${hash} is referenced but unknown`)
      bodies.push({ table: TABLE_BODY, op: "upsert", key: hash, n: null, row: { body: content, refs } satisfies BodyRow })
    }
    return [...this.out.values(), ...bodies]
  }

  private markFinished(run: string, n: number) {
    this.finishedCount += 1
    this.write({ table: TABLE_FINISHED, op: "upsert", key: run, n, row: { run } })
  }

  private next(): number {
    this.seq += 1
    return this.seq
  }

  private ref(hash: string, delta: number, body?: Body) {
    const cur = this.refs.get(hash)
    this.refs.set(hash, { delta: (cur?.delta ?? 0) + delta, ...((cur?.body ?? body) !== undefined ? { body: cur?.body ?? body } : {}) })
  }

  /** The last write of a key wins; it moves to the end so a delete always precedes a later reuse of its order. */
  private write(w: RowWrite) {
    const k = `${w.table}\u0000${w.key}`
    this.out.delete(k)
    this.out.set(k, w)
    this.view.apply([w])
  }
}

const joinWithout = (row: AutomationRow): Omit<Automation, "body"> => {
  const { body_hash: _h, ...rest } = row
  return rest
}
