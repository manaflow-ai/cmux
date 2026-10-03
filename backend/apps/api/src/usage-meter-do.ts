import type { Principal } from "@cmux/ownership"
import { UsageRecord, type Meter, type UsageSummary } from "@cmux/protocol"
import { Schema } from "effect"
import { ceilingUsd, MONEY_METERS, recordMicros, METERS, summarize, usageDomain, utcMonth, type MeterCounter, type UsageState } from "./domains/usage.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"

/** How long a record key is remembered for dedupe (longer than any run's retry window that records it twice). */
export const USAGE_KEY_RETENTION_MS = 35 * 24 * 3600_000
/** Records per `record` call (one tail invocation or one step boundary sends a handful). */
export const MAX_RECORDS_PER_CALL = 500
/** Egress requests per team per minute (abuse limit A18, automations-billing.md 5.5). */
export const EGRESS_PER_MINUTE = 600

/** The egress gateway's admission: `limited` = over the minute's limit (nothing recorded), `allowed` = under the hard cap. */
export interface EgressAdmission {
  readonly limited: boolean
  readonly allowed: boolean
}

export interface RecordResult {
  readonly recorded: number
  readonly duplicates: number
  readonly invalid: number
  /** The batch had more than MAX_RECORDS_PER_CALL records and nothing was recorded; send smaller batches. */
  readonly too_large?: true
  /** False when the team is at its hard cap (or no cap is configured): stop at the next step boundary. */
  readonly allowed: boolean
  readonly summary: UsageSummary
}

const decodeRecord = Schema.decodeUnknownOption(UsageRecord)

/**
 * UsageMeterDO: one per team, the only writer of the team's automation usage
 * ledger (decision A21, OWNERSHIP-PRINCIPLES single writer). `record` is called
 * by the API Worker's tail handler, the run's wrapped step, the egress gateway
 * and capability calls; it is idempotent by record key, keeps monthly counters,
 * and answers whether the team may keep working under its hard cap (A18).
 * `usage.cap.set` goes through the owner engine like every other op.
 */
export class UsageMeterDO extends OwnerDO<UsageState> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, usageDomain, "usage")
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS usage_ledger (
      key TEXT PRIMARY KEY, meter TEXT NOT NULL, quantity REAL NOT NULL, month TEXT NOT NULL, source TEXT NOT NULL,
      run TEXT, automation TEXT, step TEXT, attempt INTEGER, commit_sha TEXT, observed_at INTEGER NOT NULL, recorded_at INTEGER NOT NULL)`)
    ctx.storage.sql.exec(`CREATE INDEX IF NOT EXISTS usage_ledger_recorded ON usage_ledger (recorded_at)`)
    // One row per team: the current egress minute and its count (a fixed window).
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS egress_minute (id INTEGER PRIMARY KEY CHECK (id = 1), minute INTEGER NOT NULL, n INTEGER NOT NULL)`)
    // usd_micros: integer micro-dollars, the only money column (summed exactly).
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS usage_month (month TEXT NOT NULL, meter TEXT NOT NULL, quantity REAL NOT NULL, usd_micros INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (month, meter))`)
    const cols = ctx.storage.sql.exec<{ name: string }>(`PRAGMA table_info(usage_month)`).toArray()
    if (!cols.some((c) => c.name === "usd_micros")) {
      // Objects from before integer money: carry existing model spend over in the same transaction.
      ctx.storage.transactionSync(() => {
        ctx.storage.sql.exec(`ALTER TABLE usage_month ADD COLUMN usd_micros INTEGER NOT NULL DEFAULT 0`)
        ctx.storage.sql.exec(`UPDATE usage_month SET usd_micros = CAST(ROUND(quantity * 1000000) AS INTEGER) WHERE meter = 'model.spend_usd'`)
      })
    }
  }

  private ceiling() {
    return ceilingUsd(this.env.AUTOMATION_CAP_CEILING_USD)
  }

  private counters(month: string): Map<Meter, MeterCounter> {
    const rows = this.ctx.storage.sql.exec<{ meter: string; quantity: number; usd_micros: number }>(`SELECT meter, quantity, usd_micros FROM usage_month WHERE month = ?`, month).toArray()
    return new Map(rows.filter((r) => (METERS as ReadonlyArray<string>).includes(r.meter)).map((r) => [r.meter as Meter, { quantity: Number(r.quantity), usd_micros: Number(r.usd_micros) }]))
  }

  private summaryFor(entity: string, now: number): UsageSummary {
    const state = this.bind(entity).currentState
    return summarize({ ...state, owner: state.owner ?? entity }, utcMonth(now), this.counters(utcMonth(now)), this.ceiling())
  }

  protected read(state: UsageState, op: string, _params: unknown, principal: Principal): ReadResult {
    const team = state.owner ?? principal.team
    if (!team || (state.owner !== null && state.owner !== principal.team)) return { ok: false, code: "auth.forbidden", message: "not this team's usage" }
    if (op !== "usage.summary") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    const now = Date.now()
    return { ok: true, value: summarize({ ...state, owner: team }, utcMonth(now), this.counters(utcMonth(now)), this.ceiling()), revision: "" }
  }

  protected maySubscribe(state: UsageState, principal: Principal): boolean {
    return Boolean(principal.team && (state.owner === null || state.owner === principal.team))
  }

  /**
   * Records a batch in one transaction. A known key is a duplicate and counts
   * nothing; an invalid record is dropped and logged (a harness bug, never a
   * customer charge). Records count in the UTC month they are recorded in, so a
   * late or clock-skewed record still counts against the current cap.
   */
  async record(entity: string, records: ReadonlyArray<unknown>): Promise<RecordResult> {
    this.bind(entity)
    const now = Date.now()
    if (records.length > MAX_RECORDS_PER_CALL) {
      const summary = this.summaryFor(entity, now)
      return { recorded: 0, duplicates: 0, invalid: 0, too_large: true, allowed: summary.stopped === null, summary }
    }
    let recorded = 0
    let duplicates = 0
    let invalid = 0
    const sql = this.ctx.storage.sql
    this.ctx.storage.transactionSync(() => {
      for (const raw of records) {
        const r = decodeRecord(raw)
        if (r._tag === "None") {
          invalid++
          continue
        }
        const v = r.value
        // Count meters are whole units: a fraction is a harness bug, never a charge.
        if (!MONEY_METERS.has(v.meter) && !Number.isInteger(v.quantity)) {
          invalid++
          continue
        }
        const month = utcMonth(now)
        const inserted = sql.exec(
          `INSERT OR IGNORE INTO usage_ledger (key, meter, quantity, month, source, run, automation, step, attempt, commit_sha, observed_at, recorded_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          v.key, v.meter, v.quantity, month, v.source, v.run ?? null, v.automation ?? null, v.step ?? null, v.attempt ?? null, v.commit ?? null, v.observed_at, now
        ).rowsWritten
        if (inserted === 0) {
          duplicates++
          continue
        }
        recorded++
        sql.exec(
          `INSERT INTO usage_month (month, meter, quantity, usd_micros) VALUES (?, ?, ?, ?) ON CONFLICT (month, meter) DO UPDATE SET quantity = quantity + excluded.quantity, usd_micros = usd_micros + excluded.usd_micros`,
          month, v.meter, v.quantity, recordMicros(v.meter, v.quantity)
        )
      }
    })
    if (invalid > 0) console.error(JSON.stringify({ msg: "usage records refused", team: entity, invalid }))
    const summary = this.summaryFor(entity, now)
    this.scheduleAlarm()
    return { recorded, duplicates, invalid, allowed: summary.stopped === null, summary }
  }

  /**
   * The egress gateway's call per outbound request: the minute's limit first (a refused
   * request records nothing), then one `egress.requests` record under the caller's unique
   * key, then the cap. The gateway calls this once per request, so the key never repeats.
   */
  async egress(entity: string, key: string, observedAt: number): Promise<EgressAdmission> {
    this.bind(entity)
    const now = Date.now()
    const minute = Math.floor(now / 60_000)
    const sql = this.ctx.storage.sql
    const limited = this.ctx.storage.transactionSync(() => {
      const row = sql.exec<{ minute: number; n: number }>(`SELECT minute, n FROM egress_minute WHERE id = 1`).toArray()[0]
      const n = row && Number(row.minute) === minute ? Number(row.n) : 0
      if (n >= EGRESS_PER_MINUTE) return true
      sql.exec(`INSERT INTO egress_minute (id, minute, n) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET minute = excluded.minute, n = excluded.n`, minute, n + 1)
      return false
    })
    if (limited) return { limited: true, allowed: true }
    const r = await this.record(entity, [{ key, meter: "egress.requests", quantity: 1, source: "egress", observed_at: observedAt }])
    return { limited: false, allowed: r.allowed && r.invalid === 0 }
  }

  /** The cap check alone (a step boundary with nothing to record). */
  async check(entity: string): Promise<{ allowed: boolean; summary: UsageSummary }> {
    const summary = this.summaryFor(entity, Date.now())
    return { allowed: summary.stopped === null, summary }
  }

  protected override nextWakeAt(): number | null {
    const row = this.ctx.storage.sql.exec<{ at: number | null }>(`SELECT MIN(recorded_at) AS at FROM usage_ledger`).toArray()[0]
    // One hour of slack: one wake prunes a batch of keys, not one wake per key.
    return row?.at === null || row?.at === undefined ? null : Number(row.at) + USAGE_KEY_RETENTION_MS + 3600_000
  }

  /** Dedupe keys leave after their retention; monthly counters stay. */
  protected override async onWake(now: number): Promise<void> {
    this.ctx.storage.sql.exec(`DELETE FROM usage_ledger WHERE recorded_at < ?`, now - USAGE_KEY_RETENTION_MS)
  }
}
