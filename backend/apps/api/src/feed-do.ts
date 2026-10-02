import type { Principal } from "@cmux/ownership"
import { feedKindSchemas, FeedList, type FeedItem } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import { listItems } from "./domains/feed-query.ts"
import { feedCounts, feedDomain, nextFeedWake, visibleTo, type FeedState } from "./domains/feed.ts"
import { isUserClient, prunableAt, pushEligible, RETENTION_MS } from "./domains/feed-state.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"

/** How long a Mac's `active` presence counts for the push rule (feed.md 7.3). */
const MAC_ACTIVE_WINDOW_MS = 120_000

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
export class FeedDO extends OwnerDO<FeedState> {
  constructor(ctx: DurableObjectState, env: Env) {
    // Subscribers are the user's own clients; events show the acting install, never email or Stack ids.
    super(ctx, env, feedDomain, "feed", (p) => ({
      identity: p.identity,
      ...(p.kind ? { kind: p.kind } : {}),
      ...(p.user ? { user: p.user } : {}),
      ...(p.install ? { install: p.install } : {}),
      ...(p.agent ? { agent: p.agent } : {})
    }))
  }

  protected read(state: FeedState, op: string, params: unknown, principal: Principal): ReadResult {
    if (state.user && principal.user !== state.user) return { ok: false, code: "auth.forbidden", message: "not this user's feed" }
    const mine = Object.values(state.items).filter((i) => visibleTo(principal, i))
    switch (op) {
      case "feed.list": {
        const d = decodeParams<typeof FeedList.params.Type>(FeedList, params)
        if (!d.ok) return { ok: false, code: d.code, message: d.message }
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

  private macActive(now: number): boolean {
    return this.ctx.getWebSockets().some((ws) => {
      const p = (ws.deserializeAttachment() as { presence?: Presence } | null)?.presence
      return Boolean(p && p.client === "mac" && p.active && now - p.at < MAC_ACTIVE_WINDOW_MS)
    })
  }

  /**
   * Push delivery is an external effect after commit (feed.md 7.3). The APNs
   * sender belongs to the iOS lane; until it exists the decision is logged.
   */
  protected sendPush(items: ReadonlyArray<FeedItem>): void {
    for (const i of items) console.log(JSON.stringify({ msg: "feed.push.send", item: i.id, kind: i.kind, priority: i.priority }))
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
      const quiet = state.prefs.push_skip_when_mac_active && this.macActive(now)
      const send = pushDue.filter((i) => pushEligible(i) && (!quiet || i.priority === "urgent")).map((i) => i.id)
      const skip = pushDue.map((i) => i.id).filter((id) => !send.includes(id))
      const r = this.submitSystem("feed.push_due", { at: now, send, skip }, `push:${now}`)
      const result = r.frames.find((f) => f.t === "result")
      const sent = result && result.t === "result" ? ((result.value as { sent?: Array<string> }).sent ?? []) : []
      this.sendPush(sent.map((id) => engine.currentState.items[id]!).filter(Boolean))
    }
    if (due((i) => (prunableAt(i) ?? Infinity) <= now)) this.submitSystem("feed.prune", { before: now - RETENTION_MS }, `prune:${now}`)
  }
}
