import type { EventFrame, OpFrame, Principal } from "@cmux/ownership"
import { feedKindSchemas, FeedList, type FeedItem, type PushTarget } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import { listItems } from "./domains/feed-query.ts"
import { feedCounts, feedDomain, nextFeedWake, visibleTo, type FeedState } from "./domains/feed.ts"
import { isUserClient, prunableAt, pushEligible, RETENTION_MS } from "./domains/feed-state.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { FEED_ENGINE_OPTIONS, scrubFeedText } from "./feed-privacy.ts"
import type { SweepState } from "./feed-sweep.ts"
import { apnsConfig, sendApns } from "./push/apns.ts"

interface Presence {
  readonly active: boolean
  readonly client: string
  readonly at: number
}

/**
 * FeedDO: one user's feed (plans/cmux-next/feed.md, decision N10). Items,
 * answers, triage and push rules are committed through the shared owner engine.
 * Presence (which client is active) lives only in socket attachments: it is
 * client view state, used for the push decision, never committed.
 */
/** Posts per day for all scopes of one install (DO audit 5.6: a runaway agent cannot churn the event window). */
export const MAX_POSTS_PER_DAY = 5_000

export class FeedDO extends OwnerDO<FeedState> {
  constructor(ctx: DurableObjectState, env: Env) {
    // Subscribers are the user's own clients; events show the acting install, never email or Stack ids.
    super(ctx, env, feedDomain, "feed", (p) => ({
      identity: p.identity,
      ...(p.kind ? { kind: p.kind } : {}),
      ...(p.user ? { user: p.user } : {}),
      ...(p.install ? { install: p.install } : {}),
      ...(p.install_kind ? { install_kind: p.install_kind } : {}),
      ...(p.agent ? { agent: p.agent } : {})
    }), FEED_ENGINE_OPTIONS)
  }

  /** Posts per day for all scopes of one install (DO audit 5.6); a field so tests can lower it. */
  protected maxPostsPerDay = MAX_POSTS_PER_DAY

  /**
   * feed.post and feed.adopt from an install count toward its daily cap, kept in a side table (the
   * shared reducer and its vectors stay unchanged). A retry of a decided key always replays.
   */
  override async submit(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult> {
    // Every poster counts (an install, or a session by its identity); system ops do not.
    const poster = principal.kind === "system" ? undefined : (principal.install ?? principal.identity)
    if ((frame.op !== "feed.post" && frame.op !== "feed.adopt") || poster === undefined) return super.submit(entity, principal, frame)
    const day = Math.floor(Date.now() / 86_400_000)
    const sql = this.ctx.storage.sql
    const used = () => {
      if (sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'feed_daily'`).toArray().length === 0) return 0
      return Number(sql.exec<{ count: number }>(`SELECT count FROM feed_daily WHERE install = ? AND day = ?`, poster, day).toArray()[0]?.count ?? 0)
    }
    // bind() (not the cached engine, which is unset after a cold start) so a decided key always replays.
    const replay = this.isBound(entity) && this.bind(entity).gate(principal, frame) === "replay"
    if (!replay && used() >= this.maxPostsPerDay) {
      const key = String(frame.idempotency_key ?? "")
      return {
        frames: [
          { t: "reject", tx: "", idempotency_key: key, code: "feed.rate_limited", message: `at most ${this.maxPostsPerDay} posts per day per install; try again tomorrow (UTC)`, retryable: false, replayed: false },
          { t: "request-settled", tx: "", idempotency_key: key, stream: `feed:${entity}`, sequence: 0, ok: false }
        ]
      }
    }
    const res = await super.submit(entity, principal, frame)
    if (res.frames.some((f) => f.t === "result" && !f.replayed)) {
      sql.exec(`CREATE TABLE IF NOT EXISTS feed_daily (install TEXT NOT NULL, day INTEGER NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (install, day))`)
      sql.exec(`DELETE FROM feed_daily WHERE day < ?`, day)
      sql.exec(`INSERT INTO feed_daily (install, day, count) VALUES (?, ?, 1) ON CONFLICT (install, day) DO UPDATE SET count = count + 1`, poster, day)
    }
    return res
  }

  /** Text written without the redaction is scrubbed on bind (feed-privacy.ts). */
  protected override bind(entity: string) {
    const engine = super.bind(entity)
    scrubFeedText(engine)
    return engine
  }

  protected read(state: FeedState, op: string, params: unknown, principal: Principal): ReadResult {
    if (state.user && principal.user !== state.user) return { ok: false, code: "auth.forbidden", message: "not this user's feed" }
    const mine = Object.values(state.items).filter((i) => visibleTo(principal, i))
    switch (op) {
      case "feed.list": {
        const d = decodeParams<typeof FeedList.params.Type>(FeedList, params)
        if (!d.ok) return { ok: false, code: d.code, message: d.message }
        if (d.value.after !== undefined && !mine.some((i) => i.id === d.value.after)) return { ok: false, code: "validation.invalid", message: "the cursor item is gone; list again from the start" }
        return { ok: true, value: listItems(mine, d.value, Date.now()), revision: "" }
      }
      case "feed.get": {
        const id = (params as { item?: unknown } | null)?.item
        const item = typeof id === "string" ? state.items[id] : undefined
        if (!item || !visibleTo(principal, item)) return { ok: false, code: "selector.not_found", message: `no feed item ${String(id)}` }
        return { ok: true, value: { item }, revision: "" }
      }
      case "feed.counts":
        if (!isUserClient(principal)) return { ok: false, code: "auth.forbidden", message: "counts are for the user's own clients" }
        return { ok: true, value: feedCounts(state, Date.now()), revision: "" }
      case "feed.kinds":
        return { ok: true, value: { kinds: feedKindSchemas() }, revision: "" }
      default:
        return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    }
  }

  /** Only the user's own clients subscribe to the whole feed; agents watch through their daemon. */
  protected maySubscribe(state: FeedState, principal: Principal): boolean {
    return isUserClient(principal) && (!state.user || state.user === principal.user)
  }

  /**
   * Each live event carries the items its commit changed (every reducer change
   * stamps `updated_at` with the commit time, the event's `at`), and, for ops
   * that can remove items (post and adopt evict, prune drops), every id still
   * present. Clients mirror these owner-written items; they never replay ops.
   */
  /** Sweep (feed-sweep.ts): scrubs the stored text of a bound feed; reports false for an object without one. */
  async scrubIfBound(): Promise<boolean> {
    const engine = this.boundEngine
    if (!engine) return false
    scrubFeedText(engine)
    return true
  }

  /** The sweep cursor, kept only in the reserved object SWEEP_OBJECT (never a user's feed). */
  async sweepState(): Promise<SweepState> {
    return ((await this.ctx.storage.get<SweepState>("feed-sweep")) ?? { after: null, completed_at: null })
  }

  async setSweepState(state: SweepState): Promise<void> {
    await this.ctx.storage.put("feed-sweep", state)
  }

  protected override eventExtras(event: EventFrame): Record<string, unknown> | undefined {
    const state = this.boundEngine?.currentState
    if (!state) return undefined
    const items = Object.values(state.items).filter((i) => i.updated_at === event.at)
    const removes = event.op === "feed.post" || event.op === "feed.adopt" || event.op === "feed.prune"
    return { items, ...(removes ? { present: Object.keys(state.items) } : {}) }
  }

  protected override nextWakeAt(state: FeedState): number | null {
    return nextFeedWake(state)
  }

  /** `presence.set {state: {active, client}}` from a connected client (sync-and-transport.md 3.1). */
  protected override onFrame(ws: WebSocket, frame: { readonly t?: string } & Record<string, unknown>): boolean {
    if (frame.t !== "presence.set") return false
    const st = (frame.state ?? {}) as { active?: unknown; client?: unknown }
    const a = (ws.deserializeAttachment() ?? {}) as Record<string, unknown>
    const presence: Presence = { active: st.active === true, client: typeof st.client === "string" ? st.client.slice(0, 16) : "unknown", at: Date.now() }
    ws.serializeAttachment({ ...a, presence })
    return true
  }

  private macActive(): boolean {
    return this.ctx.getWebSockets().some((ws) => {
      const p = (ws.deserializeAttachment() as { presence?: Presence } | null)?.presence
      // Active until the client says otherwise (app resigns, screen sleeps or locks) or the socket closes.
      return Boolean(p && p.client === "mac" && p.active)
    })
  }

  /**
   * For Home push (UserDO): true while this user's Mac is active and the feed's
   * `push_skip_when_mac_active` preference holds (default on). The same rule as feed pushes,
   * so one presence source (the Mac's feed socket) quiets both. Only a Mac counts: a phone
   * can be suspended without saying so, while a Mac says when it resigns, sleeps or locks.
   */
  async homePushQuiet(user: string): Promise<boolean> {
    const state = this.boundEngine?.currentState
    if (state?.user && state.user !== user) return false
    return (state?.prefs.push_skip_when_mac_active ?? true) && this.macActive()
  }

  /**
   * Push delivery is an external effect after commit (feed.md 7.3): the
   * owner already recorded the decision (`feed.push_due`); this sends to the
   * user's devices (UserDO push targets) through APNs and drops tokens APNs
   * rejects. Without APNs secrets the decision is only logged.
   */
  protected async sendPush(items: ReadonlyArray<FeedItem>): Promise<void> {
    const user = this.boundEngine?.currentState.user
    const config = apnsConfig(this.env)
    if (items.length === 0 || !user) return
    if (!config) {
      for (const i of items) console.log(JSON.stringify({ msg: "feed.push.skipped", reason: "apns not configured", item: i.id }))
      return
    }
    // An effect after commit never throws: a failed send must not stop this wake's expiry and prune.
    // Delivery is at most once (feed.md 7.3): the decision is committed before the send.
    try {
      const users = this.env.USER_DO.get(this.env.USER_DO.idFromName(user))
      let targets: ReadonlyArray<PushTarget> = [...(await users.pushTargets(user))]
      for (const item of items) {
        const results = await sendApns(config, targets, item, Date.now())
        const dropped = new Set(results.filter((r) => r.outcome === "drop_target").map((r) => r.token))
        for (const token of dropped) await users.dropPushTarget(user, token, results.find((r) => r.token === token)?.reason ?? "rejected")
        targets = targets.filter((t) => !dropped.has(t.token))
        console.log(JSON.stringify({ msg: "feed.push.sent", item: item.id, results: results.map((r) => ({ outcome: r.outcome, status: r.status, reason: r.reason })) }))
      }
    } catch (e) {
      console.error(JSON.stringify({ msg: "feed.push.failed", error: String(e).slice(0, 200) }))
    }
  }

  protected override async onWake(now: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    const due = (pred: (i: FeedItem) => boolean) => Object.values(engine.currentState.items).some(pred)
    if (due((i) => i.state === "open" && i.expires_at <= now)) this.submitSystem("feed.expire", { at: now }, `expire:${now}`)
    if (due((i) => i.snoozed_until !== null && i.snoozed_until <= now)) this.submitSystem("feed.snooze_wake", { at: now }, `wake:${now}`)
    const state = engine.currentState
    const pushDue = Object.values(state.items).filter((i) => i.push_due_at !== null && i.push_due_at <= now)
    if (pushDue.length > 0) {
      const quiet = state.prefs.push_skip_when_mac_active && this.macActive()
      const send = pushDue.filter((i) => pushEligible(i) && (!quiet || i.priority === "urgent")).map((i) => i.id)
      const skip = pushDue.map((i) => i.id).filter((id) => !send.includes(id))
      const r = this.submitSystem("feed.push_due", { at: now, send, skip }, `push:${now}`)
      const result = r.frames.find((f) => f.t === "result")
      const sent = result && result.t === "result" ? ((result.value as { sent?: Array<string> }).sent ?? []) : []
      await this.sendPush(sent.map((id) => engine.currentState.items[id]!).filter(Boolean))
    }
    if (due((i) => (prunableAt(i) ?? Infinity) <= now)) this.submitSystem("feed.prune", { before: now - RETENTION_MS }, `prune:${now}`)
  }
}
