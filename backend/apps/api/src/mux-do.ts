import type { Domain, OwnerFrame, Principal } from "@cmux/ownership"
import { mux } from "@cmux/home-core"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { publicActor } from "./public-actor.ts"
import { withAdmit } from "./home-admit.ts"
import { type BrainRoute, dueWakes, durableOn, nextDeliveryAt, nextWaiting, pendWake, sendWake, settleWake, type Wake } from "./mux-wake-delivery.ts"

/**
 * MuxDO, one per chief (home-messaging.md sections 3 and 4.3): the chief's wake queue, run by
 * lane 15's pure domain in row mode (wake rows, so an offline week stays bounded). The brain
 * host subscribes to `mux:<agent>` and acks with mux.ack; ConversationDO outboxes send mux.wake.
 */
export class MuxDO extends OwnerDO<mux.MuxHead> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, withAdmit("cloud:MuxDO", mux.muxDomain as Domain<mux.MuxHead>), "mux", publicActor, {
      rowMode: { snapshotTable: mux.TABLE_WAKE, snapshotTail: 200 }
    })
  }

  /** RPC: the chief's owner (participant.avatar.get finds the account that keeps its avatar), or null. */
  async ownerOf(agent: string): Promise<string | null> {
    const row = this.boundRow()
    const head = row ? this.bind(row.entity).currentState : undefined
    return head && head.agent === agent ? (head.owner_user ?? null) : null
  }

  /**
   * The Chief's brain implementation, the one source of truth for routing (wakes here, the runs read and
   * GET/PUT /v1/chiefs/<agent>/brain-impl in the Worker). PUT writes it here first, then tells the opencode
   * brain; a failure between the two is safe both ways (an opencode wake the brain still calls pi answers
   * `impl_pi` and falls back to P; a pi Chief never reaches the opencode brain). RPC, owner-checked by the route.
   */
  async setBrainImpl(impl: "pi" | "opencode" | "durable"): Promise<void> {
    this.ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS mux_brain_impl (k INTEGER PRIMARY KEY CHECK (k = 1), impl TEXT NOT NULL)`)
    this.ctx.storage.sql.exec(`INSERT INTO mux_brain_impl (k, impl) VALUES (1, ?) ON CONFLICT (k) DO UPDATE SET impl = excluded.impl`, impl)
    this.impl = impl
  }
  async brainImplOf(): Promise<string> {
    return this.brainImpl()
  }
  private impl: string | undefined

  /** The brain_impl ("pi" when never set): local, read once per object life. */
  private brainImpl(): string {
    if (this.impl !== undefined) return this.impl
    const sql = this.ctx.storage.sql
    this.impl = sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'mux_brain_impl'`).toArray().length === 0 ? "pi" : (sql.exec<{ impl: string }>(`SELECT impl FROM mux_brain_impl WHERE k = 1`).toArray()[0]?.impl ?? "pi")
    return this.impl
  }

  /** The chief itself (agent token) or its owner. */
  private allowed(head: mux.MuxHead, p: Principal): boolean {
    if (p.kind === "agent") return p.agent !== undefined && p.agent === head.agent
    // A chief token (install with agent) reaches only its own chief's queue; the owner's other tokens reach all of them.
    if (p.kind === "install" && p.agent !== undefined) return p.agent === head.agent && p.user === head.owner_user
    return (p.kind === "session" || p.kind === "install") && p.user !== undefined && p.user === head.owner_user
  }

  protected maySubscribe(head: mux.MuxHead, principal: Principal): boolean {
    return this.allowed(head, principal)
  }

  /**
   * A committed wake (a new queue row, not a duplicate) of a cloud-brain chief also goes to its Durable
   * Object brain, where CHIEF_BRAIN_ENABLED is "1": only to the Chief's own brain (brain_impl, cached here
   * by PUT .../brain-impl), so a pi Chief's wake never waits on the opencode brain object. Delivery is
   * at least once (mux-wake-delivery.ts): the wake stays a row here until the brain's RPC answers, and the
   * alarm sends it again with backoff after an eviction or a deploy reset of the brain; brains take a
   * repeated wake idempotently. The queue row itself stays until the brain (or a brain host) acks it.
   */
  protected afterOp(_principal: Principal, op: string, frames: ReadonlyArray<OwnerFrame>) {
    if (op !== "mux.wake" || this.env.CHIEF_BRAIN_ENABLED !== "1") return
    const result = frames.find((f) => f.t === "result") as { value?: mux.WakeItem | null; replayed?: boolean } | undefined
    const head = this.boundEngine?.currentState
    const item = result?.value
    // A chief run locally (mux.configure brain "local") is its host's alone: no second answer from here.
    if (!item || result?.replayed || !head?.agent || !head.owner_user || head.brain !== "cloud") return
    // `at`: when this queue took the wake (the brain's Run.timing mux_at; a resend from the alarm has none).
    const wake = { agent: head.agent, owner: head.owner_user, conversation: item.conversation, seq: item.seq, reason: item.reason, at: Date.now() }
    const now = pendWake(this.ctx.storage.sql, wake, Date.now())
    this.scheduleAlarm()
    // An older wake of this conversation is still undelivered: this one goes after it, from the alarm.
    if (now) this.ctx.waitUntil(this.deliver(wake))
  }

  /** The brain this Chief's wakes go to: its brain_impl when this deployment runs it, else P. */
  private route(): BrainRoute {
    const impl = this.brainImpl()
    if (impl === "opencode" && this.env.CHIEF_OPENCODE_ENABLED === "1" && this.env.OPENCODE_BRAIN_DO !== undefined) return "opencode"
    if (impl === "durable" && durableOn(this.env)) return "durable"
    return "pi"
  }

  /**
   * Sends `wake`, then (when it was delivered) the conversation's wakes that came while it was in flight,
   * in seq order, at once (a burst of messages reaches the brain in one run, not at the next alarm).
   * `chain` false: only this wake (the alarm walks its own due rows in order).
   */
  private async deliver(wake: Wake, chain = true): Promise<boolean> {
    const ok = await this.sendOne(wake)
    let w: Wake = wake
    for (let sent = ok; sent && chain; ) {
      const next = nextWaiting(this.ctx.storage.sql, w, Date.now())
      if (!next) break
      w = { agent: wake.agent, owner: wake.owner, ...next }
      sent = await this.sendOne(w)
    }
    return ok
  }

  private async sendOne(wake: Wake): Promise<boolean> {
    const ok = await sendWake(this.env, wake, this.route())
    settleWake(this.ctx.storage.sql, wake, ok, Date.now())
    this.scheduleAlarm()
    return ok
  }

  /** The alarm sends the undelivered wakes that are due (mux-wake-delivery.ts). */
  protected override async onWake(now: number): Promise<void> {
    const head = this.boundEngine?.currentState
    const due = dueWakes(this.ctx.storage.sql, now)
    if (!head?.agent || !head.owner_user || head.brain !== "cloud" || this.env.CHIEF_BRAIN_ENABLED !== "1") {
      for (const rows of due.values()) for (const d of rows) settleWake(this.ctx.storage.sql, d, true, now)
      return
    }
    const { agent, owner_user: owner } = head
    // Conversations in parallel, each in seq order, stopping at its first failure (order kept); every send is time-limited.
    await Promise.allSettled([...due.values()].map(async (rows) => {
      for (const d of rows) if (!(await this.deliver({ agent, owner, ...d }, false))) return
    }))
  }

  /** The next undelivered wake's due time shares the one alarm with the outbox drain. */
  protected override nextWakeAt(_state: mux.MuxHead, _now: number): number | null {
    return nextDeliveryAt(this.ctx.storage.sql)
  }

  /** mux.queue: the head (cursors and pending counts); wake rows come with the snapshot. */
  protected read(head: mux.MuxHead, op: string, _params: unknown, principal: Principal): ReadResult {
    if (!this.allowed(head, principal)) return { ok: false, code: "auth.forbidden", message: "not this chief or its owner" }
    if (op !== "mux.queue") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    return { ok: true, value: head, revision: "" }
  }
}
