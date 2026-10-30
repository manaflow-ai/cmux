import type { Principal } from "@cmux/ownership"
import { UsageRecord, type Meter, type UsageSummary } from "@cmux/protocol"
import { Schema } from "effect"
import { ceilingUsd, MONEY_METERS, recordMicros, METERS, summarize, usageDomain, utcMonth, type MeterCounter, type UsageState } from "./domains/usage.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { addUserSpend, BILLABLE_GRACE_MS, ensureUserTables, expireUserReservations, nextUserWake, recordCostMicros, reserveUser, settleCall, userSpentMicros, type UserReserve } from "./usage-user.ts"
import type { IncludedMode } from "./billing-catalog.ts"
import { creditAdd, creditBalance, creditCustomer, creditNoticeOnce, creditRelease, creditReserve, creditSettle, ensureCreditTables, expireCreditHolds, nextCreditWake, setCreditCustomer, type ChiefCallCap, type CreditBalance, type CreditReserve } from "./usage-credits.ts"
import { autoReloadDecision, chargeSavedCard, endRun, failAutoReload, monthReloaded, readAutoReload, startRun, writeAutoReload, type AutoReloadSettings } from "./credits-autoreload.ts"
import { MIRROR_DEADLINE_MS, mirrorCredits, mirrorDue, mirrorFailed } from "./credits-mirror.ts"
import { currentBillable, ensureBillingTables, markBillable, previousPush, pushState, recordPush, lastSeenSeats, setTeamMode, teamModeAt, teamModeHistory, type BillableInfo, type ModeChange, type PushInfo } from "./usage-billing-store.ts"

/** How long a record key is remembered for dedupe (longer than any run's retry window that records it twice). */
export const USAGE_KEY_RETENTION_MS = 35 * 24 * 3600_000
/**
 * How long a billable fact (a money meter row: model.spend_usd) is kept: the bill and its later
 * corrections read these rows (cx-y79zh S2, plans/cmux-next/usage-billing.md), so they outlive the
 * dedupe window by far. Count-meter rows are priced 0 to customers today and keep the dedupe window.
 */
export const BILLABLE_FACT_RETENTION_MS = 400 * 24 * 3600_000
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
  /** False when the team is at its hard cap (or an invalid ceiling is set): stop at the next step boundary. */
  readonly allowed: boolean
  /** With `limit`: false when that member reached their monthly AI limit (cx-ds09i); stop at the next step boundary. */
  readonly user_allowed?: boolean
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
    // Per meter: the prune's oldest row per retention, its deletes and the billing level (S2 review P2-1).
    ctx.storage.sql.exec(`CREATE INDEX IF NOT EXISTS usage_ledger_meter_recorded ON usage_ledger (meter, recorded_at)`)
    // A fact names its member, and a correction names the fact it corrects (cx-y79zh S1); older objects get the columns.
    const ledgerCols = new Set(ctx.storage.sql.exec<{ name: string }>(`PRAGMA table_info(usage_ledger)`).toArray().map((c) => c.name))
    if (!ledgerCols.has("user")) ctx.storage.sql.exec(`ALTER TABLE usage_ledger ADD COLUMN user TEXT`)
    if (!ledgerCols.has("corrects")) ctx.storage.sql.exec(`ALTER TABLE usage_ledger ADD COLUMN corrects TEXT`)
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
    ensureUserTables(ctx.storage.sql)
    ensureBillingTables(ctx.storage.sql)
    ensureCreditTables(ctx.storage)
  }

  /** The usage sync saw this team on a billable subscription (a usage item) whose period ends at `periodEnd` (s), with its included amount. */
  async markBillable(entity: string, subscription: string, periodEnd: number, info?: BillableInfo): Promise<void> {
    this.bind(entity)
    markBillable(this.ctx.storage.sql, subscription, periodEnd, Date.now(), info)
  }

  /** The usage sync's last sent identifier for a subscription period, or null (never sent, or the team never used the meter). */
  async pushedLevel(entity: string, subscription: string, periodStart: number): Promise<string | null> {
    return (await this.pushState(entity, subscription, periodStart))?.identifier ?? null
  }

  /** The usage sync's last push for a subscription period: its identifier, mode and seats (S5 included modes). */
  async pushState(entity: string, subscription: string, periodStart: number): Promise<{ identifier: string; mode: IncludedMode; seats: number; event_ts: number | null } | null> {
    if (!this.isBound(entity)) return null
    return pushState(this.ctx.storage.sql, subscription, periodStart)
  }

  /** The usage sync sent `identifier` (level `micros`) for this subscription period [start, end) (seconds). */
  async recordPush(entity: string, subscription: string, periodStart: number, periodEnd: number, identifier: string, micros: number, info?: PushInfo): Promise<void> {
    this.bind(entity)
    recordPush(this.ctx.storage.sql, subscription, periodStart, periodEnd, identifier, micros, Date.now(), info)
  }

  /** The latest period before `beforeStart` that the sync sent for this subscription (its final push after renewal). */
  async previousPush(entity: string, subscription: string, beforeStart: number): Promise<{ period_start: number; period_end: number; mode: IncludedMode; seats: number; included_usd: number | null } | null> {
    if (!this.isBound(entity)) return null
    return previousPush(this.ctx.storage.sql, subscription, beforeStart)
  }

  /** The included mode of this subscription period (start in s): the mode it was pushed in, else the setting in force at its start. */
  async periodMode(entity: string, subscription: string, periodStart: number): Promise<IncludedMode> {
    if (!this.isBound(entity)) return "per_team"
    return pushState(this.ctx.storage.sql, subscription, periodStart)?.mode ?? teamModeAt(this.ctx.storage.sql, periodStart * 1000)
  }

  /** The operator's included-mode setting (POST /v1/internal/billing/team-mode): recorded now, in force from the next period start. */
  async setIncludedMode(entity: string, mode: IncludedMode, actor: string, reason: string | null): Promise<{ before: IncludedMode; changed: boolean }> {
    this.bind(entity)
    return setTeamMode(this.ctx.storage.sql, mode, actor, reason, Date.now())
  }

  /** The setting history and the mode in force now (for the operator read). Never binds. */
  async includedModes(entity: string): Promise<{ requested: IncludedMode; in_force_now: IncludedMode; changes: ReadonlyArray<ModeChange> }> {
    if (!this.isBound(entity)) return { requested: "per_team", in_force_now: "per_team", changes: [] }
    const h = teamModeHistory(this.ctx.storage.sql)
    const mark = currentBillable(this.ctx.storage.sql, Date.now(), BILLABLE_GRACE_MS)
    const start = mark?.period_start !== undefined ? mark.period_start * 1000 : Date.parse(`${utcMonth(Date.now())}-01T00:00:00Z`)
    return { ...h, in_force_now: mark?.mode ?? teamModeAt(this.ctx.storage.sql, start) }
  }

  /**
   * team.ai_limit.get, the team line (S5 console): with a billable mark in force, the billing period's
   * settled level against the included amount the sync saw (x seats per seat); otherwise this UTC
   * month's model spend (settled plus open, what the included-amount stop counts). Never binds.
   */
  async teamUsage(entity: string): Promise<{ billable: ({ period_start: number | null; period_end: number; mode: IncludedMode; seats: number; included_usd: number | null; spent_usd: number }) | null; month_spent_usd: number; unbilled: { mode: IncludedMode; seats: number } }> {
    if (!this.isBound(entity)) return { billable: null, month_spent_usd: 0, unbilled: { mode: "per_team", seats: 1 } }
    const sql = this.ctx.storage.sql
    const now = Date.now()
    const month = utcMonth(now)
    const spent = Number(sql.exec<{ m: number | null }>(`SELECT usd_micros AS m FROM usage_month WHERE month = ? AND meter = 'model.spend_usd'`, month).toArray()[0]?.m ?? 0)
    const open = Number(sql.exec<{ m: number | null }>(`SELECT SUM(micros) AS m FROM user_reservation WHERE month = ?`, month).toArray()[0]?.m ?? 0)
    const month_spent_usd = Math.round(spent + open) / 1_000_000
    const mark = currentBillable(sql, now, BILLABLE_GRACE_MS)
    // As the stop counts it (usage-user.ts includedRefusal): the mode in force at the month start, the last billable seats.
    const unbilled = teamModeAt(sql, Date.parse(`${month}-01T00:00:00Z`)) === "per_seat" ? { mode: "per_seat" as const, seats: lastSeenSeats(sql, now) } : { mode: "per_team" as const, seats: 1 }
    if (!mark) return { billable: null, month_spent_usd, unbilled }
    const mode = mark.mode ?? "per_team"
    const seats = mark.seats ?? 1
    const level = mark.period_start !== undefined ? await this.level(entity, mark.period_start * 1000, mark.period_end * 1000) : null
    return {
      billable: { period_start: mark.period_start ?? null, period_end: mark.period_end, mode, seats, included_usd: mark.included_usd === undefined ? null : mode === "per_seat" ? mark.included_usd * seats : mark.included_usd, spent_usd: level ? level.micros / 1_000_000 : month_spent_usd },
      month_spent_usd,
      unbilled
    }
  }

  /** Model router (inference/route.ts): reserve `maxMicros` of the member's monthly limit before the upstream call (usage-user.ts). */
  async reserveUser(entity: string, user: string, id: string, maxMicros: number, limitMicros: number, includedMicros?: number): Promise<UserReserve> {
    this.bind(entity)
    const now = Date.now()
    const r = reserveUser(this.ctx.storage, utcMonth(now), user, id, maxMicros, limitMicros, now, includedMicros)
    if (r.ok) this.scheduleAlarm()
    return r
  }

  /**
   * The call ended (`actualMicros`) or never reached a provider (null: the reservation is dropped).
   * One transaction writes the call's one fact, the member's spend and the team's model spend
   * (usage-user.ts settleCall), so the member limit and the team counter cannot disagree.
   */
  async settleCall(entity: string, id: string, actualMicros: number | null): Promise<void> {
    this.bind(entity)
    settleCall(this.ctx.storage, id, actualMicros, Date.now())
  }

  /** The pre-S1 name, kept for one release: a Worker isolate from before the deploy still calls it (review P3). */
  async settleUser(entity: string, id: string, actualMicros: number | null): Promise<void> {
    return this.settleCall(entity, id, actualMicros)
  }

  /** Prepaid credits (usage-credits.ts, credits.ts): money in, once per `key` (a paid top-up or an operator grant). */
  async creditAdd(entity: string, key: string, kind: "topup" | "grant", micros: number, actor: string, reason: string | null): Promise<{ added: boolean; balance_micros: number }> {
    this.bind(entity)
    const r = creditAdd(this.ctx.storage, key, kind, micros, actor, reason, Date.now())
    this.scheduleMirror()
    return r
  }

  /** Prepaid credits: hold a model call's maximum price before the call (refused below it). */
  async creditReserve(entity: string, id: string, maxMicros: number, chief: string | null, conversation: string | null, cap?: ChiefCallCap): Promise<CreditReserve> {
    this.bind(entity)
    const r = creditReserve(this.ctx.storage, id, maxMicros, chief, conversation, Date.now(), cap)
    if (r.ok) this.scheduleAlarm()
    return r
  }

  /** The team's payment-service customer for a key mode (one per team), or null. Never binds. */
  async creditCustomer(entity: string, mode: "test" | "live"): Promise<string | null> {
    return this.isBound(entity) ? creditCustomer(this.ctx.storage.sql, mode) : null
  }

  /** Records the team's customer for a key mode; the first one stays. Returns the one kept. */
  async setCreditCustomer(entity: string, mode: "test" | "live", customer: string): Promise<string> {
    this.bind(entity)
    const kept = setCreditCustomer(this.ctx.storage, mode, customer, Date.now())
    this.scheduleMirror()
    return kept
  }

  /** Prepaid credits: the call's real price replaces its hold (or is charged once without one). */
  async creditSettle(entity: string, id: string, priceMicros: number, costMicros: number, chief: string | null, conversation: string | null): Promise<{ charged: boolean; balance_micros: number }> {
    this.bind(entity)
    const r = creditSettle(this.ctx.storage, id, priceMicros, costMicros, chief, conversation, Date.now())
    this.scheduleMirror()
    // Auto-reload (credits-autoreload.ts): a charge that drops the balance below the threshold reloads.
    if (r.charged) this.ctx.waitUntil(this.autoReload(entity))
    return r
  }

  /** The reload running now, if any (tests await it with autoReloadIdle). */
  private reloading: Promise<void> | null = null

  /** Credits auto-reload settings with this month's reloads. Never binds. */
  async autoReloadGet(entity: string): Promise<(AutoReloadSettings & { last_error: string | null; last_error_at: number | null; month_reloaded_micros: number }) | null> {
    if (!this.isBound(entity)) return null
    const s = readAutoReload(this.ctx.storage.sql)
    return s ? { ...s, month_reloaded_micros: monthReloaded(this.ctx.storage.sql, Date.now()).micros } : null
  }

  /** Saves the settings; turning it on below the threshold reloads at once (awaited, so the answer shows it). */
  async autoReloadSet(entity: string, settings: AutoReloadSettings, by: string): Promise<void> {
    this.bind(entity)
    writeAutoReload(this.ctx.storage.sql, settings, by, Date.now())
    await this.autoReload(entity)
  }

  /** Resolves when no reload is running (tests). */
  async autoReloadIdle(): Promise<void> {
    while (this.reloading) await this.reloading
  }

  /** One reload when the decision says so; a refused charge turns auto-reload off with its reason. */
  private autoReload(entity: string): Promise<void> {
    if (this.reloading) return this.reloading
    const sql = this.ctx.storage.sql
    const settings = readAutoReload(sql)
    if (!settings?.enabled) return Promise.resolve()
    const now = Date.now()
    const month = monthReloaded(sql, now)
    const available = creditBalance(sql, now, 1).available_micros
    const micros = autoReloadDecision(settings, available, month.micros, month.inFlight)
    if (micros === null) return Promise.resolve()
    const customer = creditCustomer(sql, "test")
    if (!customer) {
      failAutoReload(sql, "no saved card", now)
      return Promise.resolve()
    }
    const runKey = `${entity}:${new Date(now).toISOString().slice(0, 7)}:${month.count + 1}`
    startRun(sql, runKey, micros, now)
    this.reloading = (async () => {
      const r = await chargeSavedCard(this.env, entity, customer, micros, runKey)
      if (r.ok) {
        endRun(sql, runKey, "succeeded", r.intent)
        creditAdd(this.ctx.storage, `autoreload:${r.intent}`, "topup", micros, "auto-reload", null, Date.now())
        this.scheduleMirror()
        console.log(JSON.stringify({ msg: "credits.autoreload", team: entity, usd: micros / 1_000_000, intent: r.intent }))
      } else {
        endRun(sql, runKey, "failed", null)
        failAutoReload(sql, r.reason, Date.now())
        console.warn(JSON.stringify({ msg: "credits.autoreload_failed", team: entity, reason: r.reason.slice(0, 200) }))
      }
    })().finally(() => {
      this.reloading = null
    })
    return this.reloading
  }

  /** Prepaid credits: the call never reached a provider. */
  async creditRelease(entity: string, id: string): Promise<boolean> {
    if (!this.isBound(entity)) return false
    const gone = creditRelease(this.ctx.storage, id, Date.now())
    this.scheduleMirror()
    return gone
  }

  /** Prepaid credits: true the first time a conversation is told the team is out of credits (until money comes in). */
  async creditNoticeOnce(entity: string, conversation: string): Promise<boolean> {
    this.bind(entity)
    return creditNoticeOnce(this.ctx.storage.sql, conversation, Date.now())
  }

  /** Prepaid credits read (GET /v1/credits): balance, holds, spend per chief since `since`, newest entries. Never binds. */
  async creditBalance(entity: string, since: number, limit = 20): Promise<CreditBalance> {
    if (!this.isBound(entity)) return { balance_micros: 0, held_micros: 0, available_micros: 0, chiefs: [], entries: [] }
    return creditBalance(this.ctx.storage.sql, since, Math.min(Math.max(1, Math.floor(limit)), 100))
  }

  /** team.ai_limit.get: this month's spend (USD, settled plus open) of the users named, and only those. */
  async userSpends(entity: string, users: ReadonlyArray<string>): Promise<Record<string, number>> {
    this.bind(entity)
    const month = utcMonth(Date.now())
    const out: Record<string, number> = {}
    for (const u of users.slice(0, 500)) {
      const { spent, open } = userSpentMicros(this.ctx.storage.sql, month, u)
      out[u] = Math.round(spent + open) / 1_000_000
    }
    return out
  }

  /** A metered automation step boundary: may this member's run go on under `limitMicros` this month? */
  async userAllowed(entity: string, user: string, limitMicros: number): Promise<{ allowed: boolean; spent_usd: number }> {
    this.bind(entity)
    const { spent, open } = userSpentMicros(this.ctx.storage.sql, utcMonth(Date.now()), user)
    return { allowed: spent + open < limitMicros, spent_usd: Math.round(spent) / 1_000_000 }
  }

  /**
   * The credits mirror to the billing database is on here: the PS_MYSQL binding, and CREDITS_MIRROR
   * "mysql" or the development environment (its Vitess branch has the tables; no var change is needed
   * there, so a skipped development deploy cannot leave the deploy's vars guard stuck). "off" stops it.
   */
  private mirrorOn(): boolean {
    if (this.env.PS_MYSQL === undefined || this.env.CREDITS_MIRROR === "off") return false
    return this.env.CREDITS_MIRROR === "mysql" || this.env.ENVIRONMENT === "development"
  }

  private scheduleMirror(): void {
    if (this.mirrorOn()) this.scheduleAlarm()
  }

  /** One mirror run from the alarm; a failure is logged (codes only) and retried later, never thrown. */
  private async runMirror(entity: string, now: number): Promise<void> {
    const due = mirrorDue(this.ctx.storage.sql)
    if (due === null || due > now) return
    let client: { end(): Promise<void>; destroy(): void } | undefined
    let timer: ReturnType<typeof setTimeout> | undefined
    let late = false
    try {
      const { connectMysql } = await import("./mysql-connect.ts")
      const c = await connectMysql(this.env.PS_MYSQL!, { timeoutMs: 5_000 })
      client = c
      // One deadline for the whole run, so a hung query never holds the alarm (hold expiry, outbox) for long.
      const deadline = Date.now() + MIRROR_DEADLINE_MS
      const expired = new Promise<never>((_, reject) => (timer = setTimeout(() => [(late = true), reject(Object.assign(new Error("mirror deadline"), { code: "MIRROR_DEADLINE" }))], Math.max(0, deadline - Date.now()))))
      expired.catch(() => undefined)
      const bounded = { query: (q: string, v?: Array<unknown>) => Promise.race([c.query(q, v), expired]) }
      const r = await mirrorCredits(this.ctx.storage, entity, bounded)
      if (r.entries > 0) console.log(JSON.stringify({ msg: "credits.mirror", team: entity, entries: r.entries, version: r.version }))
    } catch (e) {
      const err = (e as { code?: unknown; errno?: unknown } | null) ?? {}
      const failures = mirrorFailed(this.ctx.storage.sql, now)
      console.error(JSON.stringify({ msg: "credits.mirror_failed", team: entity, failures, code: String(err.code ?? ""), errno: typeof err.errno === "number" ? err.errno : null }))
    } finally {
      clearTimeout(timer)
      // After the deadline a hung query sits ahead of a graceful end: close the socket instead.
      if (late) client?.destroy()
      else await client?.end().catch(() => undefined)
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
  async record(entity: string, records: ReadonlyArray<unknown>, limit?: { readonly user: string; readonly limitMicros: number }): Promise<RecordResult> {
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
          `INSERT OR IGNORE INTO usage_ledger (key, meter, quantity, month, source, run, automation, step, attempt, commit_sha, user, observed_at, recorded_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          v.key, v.meter, v.quantity, month, v.source, v.run ?? null, v.automation ?? null, v.step ?? null, v.attempt ?? null, v.commit ?? null, v.user ?? null, v.observed_at, now
        ).rowsWritten
        if (inserted === 0) {
          duplicates++
          continue
        }
        recorded++
        // A record that names its member (an automation run's owner) counts against their monthly limit too.
        if (v.user) addUserSpend(sql, month, v.user, recordCostMicros(v.meter, v.quantity))
        sql.exec(
          `INSERT INTO usage_month (month, meter, quantity, usd_micros) VALUES (?, ?, ?, ?) ON CONFLICT (month, meter) DO UPDATE SET quantity = quantity + excluded.quantity, usd_micros = usd_micros + excluded.usd_micros`,
          month, v.meter, v.quantity, recordMicros(v.meter, v.quantity)
        )
      }
    })
    if (invalid > 0) console.error(JSON.stringify({ msg: "usage records refused", team: entity, invalid }))
    const summary = this.summaryFor(entity, now)
    this.scheduleAlarm()
    const member = limit ? userSpentMicros(sql, utcMonth(now), limit.user) : undefined
    return { recorded, duplicates, invalid, allowed: summary.stopped === null, summary, ...(member && limit ? { user_allowed: member.spent + member.open < limit.limitMicros } : {}) }
  }

  /**
   * The egress gateway's admission per outbound request: refused at the hard cap (checked
   * first, nothing counted), then the minute's limit. Counting happens in `egressDone` after
   * the upstream answered (review P2: no ledger row per request, no count for a refused or
   * failed request).
   */
  async egressAdmit(entity: string): Promise<EgressAdmission> {
    this.bind(entity)
    const now = Date.now()
    if (this.summaryFor(entity, now).stopped !== null) return { limited: false, allowed: false }
    const minute = Math.floor(now / 60_000)
    const sql = this.ctx.storage.sql
    const limited = this.ctx.storage.transactionSync(() => {
      const row = sql.exec<{ minute: number; n: number }>(`SELECT minute, n FROM egress_minute WHERE id = 1`).toArray()[0]
      const n = row && Number(row.minute) === minute ? Number(row.n) : 0
      if (n >= EGRESS_PER_MINUTE) return true
      sql.exec(`INSERT INTO egress_minute (id, minute, n) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET minute = excluded.minute, n = excluded.n`, minute, n + 1)
      return false
    })
    return { limited, allowed: true }
  }

  /** One answered egress request: added to the month's `egress.requests` counter (no ledger row; price 0). */
  async egressDone(entity: string): Promise<void> {
    this.bind(entity)
    this.ctx.storage.sql.exec(
      `INSERT INTO usage_month (month, meter, quantity, usd_micros) VALUES (?, 'egress.requests', 1, ?) ON CONFLICT (month, meter) DO UPDATE SET quantity = quantity + 1, usd_micros = usd_micros + excluded.usd_micros`,
      utcMonth(Date.now()), recordMicros("egress.requests", 1)
    )
  }

  /** The cap check alone (a step boundary with nothing to record). */
  async check(entity: string): Promise<{ allowed: boolean; summary: UsageSummary }> {
    const summary = this.summaryFor(entity, Date.now())
    return { allowed: summary.stopped === null, summary }
  }

  protected override nextWakeAt(): number | null {
    const sql = this.ctx.storage.sql
    // One index search per meter (usage_ledger_meter_recorded, `meter = ?`); a GROUP BY scans the whole index.
    const times: number[] = []
    for (const meter of METERS) {
      const at = sql.exec<{ at: number | null }>(`SELECT MIN(recorded_at) AS at FROM usage_ledger WHERE meter = ?`, meter).toArray()[0]?.at
      // One hour of slack: one wake prunes a batch of keys, not one wake per key.
      if (at !== null && at !== undefined) times.push(Number(at) + (MONEY_METERS.has(meter) ? BILLABLE_FACT_RETENTION_MS : USAGE_KEY_RETENTION_MS) + 3600_000)
    }
    const reservations = nextUserWake(sql)
    if (reservations !== null) times.push(reservations)
    const holds = nextCreditWake(sql)
    if (holds !== null) times.push(holds)
    const mirror = this.mirrorOn() ? mirrorDue(sql) : null
    if (mirror !== null) times.push(mirror)
    return times.length === 0 ? null : Math.min(...times)
  }

  /** Dedupe keys leave after their retention, billable facts after theirs; monthly counters stay; stale member reservations are charged. */
  protected override async onWake(now: number): Promise<void> {
    this.ctx.storage.sql.exec(`DELETE FROM usage_ledger WHERE meter != 'model.spend_usd' AND recorded_at < ?`, now - USAGE_KEY_RETENTION_MS)
    this.ctx.storage.sql.exec(`DELETE FROM usage_ledger WHERE meter = 'model.spend_usd' AND recorded_at < ?`, now - BILLABLE_FACT_RETENTION_MS)
    this.ctx.storage.sql.exec(`DELETE FROM usage_push WHERE pushed_at < ?`, now - BILLABLE_FACT_RETENTION_MS)
    expireCreditHolds(this.ctx.storage, now, this.mirrorOn())
    expireUserReservations(this.ctx.storage, now, utcMonth(now))
    const team = this.boundRow()?.entity
    if (this.mirrorOn() && team) await this.runMirror(team, now)
  }

  /**
   * The billing level (cx-y79zh S2): the sum of the team's settled AI spend facts recorded in
   * [from, to), corrections included, in integer micro-dollars. Pass-through pricing: the billed
   * amount is our cost (AI_PRICE_VERSION). The reconcile worker sends this level, never deltas.
   */
  async level(entity: string, from: number, to: number): Promise<{ micros: number; facts: number; last_at: number | null }> {
    // A team that never used the meter has no facts; a read does not bind (create) its object (S2 review P3).
    if (!this.isBound(entity)) return { micros: 0, facts: 0, last_at: null }
    const row = this.ctx.storage.sql.exec<{ micros: number | null; facts: number; last_at: number | null }>(
      `SELECT SUM(CAST(ROUND(quantity * 1000000) AS INTEGER)) AS micros, COUNT(*) AS facts, MAX(recorded_at) AS last_at FROM usage_ledger WHERE meter = 'model.spend_usd' AND recorded_at >= ? AND recorded_at < ?`,
      from, to
    ).toArray()[0]
    return { micros: Number(row?.micros ?? 0), facts: Number(row?.facts ?? 0), last_at: row?.last_at === null || row?.last_at === undefined ? null : Number(row.last_at) }
  }
}
