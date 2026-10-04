import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { OwnerEngine, type OwnerFrame, type Principal, type SqlStore } from "@cmux/ownership"
import { schedulerDomain, type SchedulerState } from "../../src/domains/scheduler.ts"

/**
 * A SchedulerDO engine on a fresh Durable Object's SQLite with a fake clock ((g) tests): the real
 * reducer, row store and head guard, without the run-creation rate limit's real-time waits.
 * Options match SchedulerDO's row mode; the table prefix keeps it apart from the object's own engine.
 */
export const TEAM = "team_rowsrowsrowsrowsrows0"
export const USER: Principal = { identity: "session:user_rowsrowsrowsrowsrows", kind: "session", user: "user_rowsrowsrowsrowsrows", team: TEAM }
export const SYSTEM: Principal = { identity: "system:scheduler", kind: "system" }
export const PRIVATE_TABLES = ["automation", "run", "body", "finished"]

export interface Harness {
  readonly engine: OwnerEngine<SchedulerState>
  readonly sql: SqlStore
  /** Advances the fake clock (ms). */
  tick(ms: number): void
  now(): number
  /** One op; returns the result value or throws with the reject code. */
  op(p: Principal, op: string, params: unknown): any
  /** The committed head as stored. */
  headJson(): string
  /** Rows of one scheduler table, as stored. */
  rows(table: string): Array<{ k: string; n: number | null; json: any }>
  /** One stored row, or undefined. */
  row(table: string, key: string): any
}

const runIn = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: unknown, state: DurableObjectState) => Promise<T>) => Promise<T>

/** Runs `fn` with a harness on a fresh, never bound SchedulerDO. */
export const withSchedulerEngine = async <T>(name: string, fn: (h: Harness) => Promise<T> | T): Promise<T> => {
  const ns = (env as unknown as { SCHEDULER_DO: DurableObjectNamespace }).SCHEDULER_DO
  return runIn(ns.get(ns.idFromName(`engine-${name}-${crypto.randomUUID()}`)), async (_i, state) => {
    const sql: SqlStore = {
      exec: <R>(q: string, ...params: Array<unknown>) => state.storage.sql.exec(q, ...params).toArray() as Array<R>,
      transaction: <R>(f: () => R): R => state.storage.transactionSync(f)
    }
    let clock = Date.UTC(2026, 9, 4, 12, 0, 0)
    const engine = new OwnerEngine<SchedulerState>(sql, schedulerDomain, {
      stream: `scheduler:${TEAM}`,
      prefix: "t_",
      rowMode: { snapshotTable: "run", snapshotTail: 0 },
      redact: { privateTables: PRIVATE_TABLES },
      now: () => clock
    })
    let key = 0
    const h: Harness = {
      engine,
      sql,
      tick: (ms) => void (clock += ms),
      now: () => clock,
      op: (p, name, params) => {
        const frames: Array<OwnerFrame> = []
        engine.submit(p, { t: "op", op: name, params, idempotency_key: `k${key++}` }, (_t, f) => frames.push(f))
        const out = frames.find((f) => f.t === "result" || f.t === "reject")
        if (!out || out.t === "reject") throw Object.assign(new Error(`${name}: ${out && out.t === "reject" ? `${out.code} ${out.message}` : "no reply"}`), { code: out && out.t === "reject" ? out.code : "none" })
        return out.t === "result" ? out.value : undefined
      },
      headJson: () => String(sql.exec<{ json: string }>("SELECT json FROM t_state WHERE id = 1")[0]?.json ?? ""),
      row: (table, k) => {
        const r = sql.exec<{ json: string }>("SELECT json FROM t_rows WHERE tbl = ? AND k = ?", table, k)[0]
        return r ? JSON.parse(r.json) : undefined
      },
      rows: (table) => sql.exec<{ k: string; n: number | null; json: string }>("SELECT k, n, json FROM t_rows WHERE tbl = ? ORDER BY k", table).map((r) => ({ k: r.k, n: r.n, json: JSON.parse(r.json) }))
    }
    h.op(SYSTEM, "scheduler.run_policy", { version: 1, runs_allowed: true })
    return fn(h)
  })
}
