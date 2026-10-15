import type { Domain, OwnerFrame, Principal } from "@cmux/ownership"
import { mux } from "@cmux/home-core"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { publicActor } from "./public-actor.ts"
import { withAdmit } from "./home-admit.ts"
import { brainName } from "./chief-brain/brain-do.ts"

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
   * Object brain for that conversation (chief-brain/brain-do.ts), where CHIEF_BRAIN_ENABLED is "1". The brain answers only when its owner
   * turned it on; otherwise it returns at once. Delivery is best effort: the wake row stays in the
   * queue until the brain (or a brain host) acks it.
   */
  protected afterOp(_principal: Principal, op: string, frames: ReadonlyArray<OwnerFrame>) {
    if (op !== "mux.wake" || this.env.CHIEF_BRAIN_ENABLED !== "1") return
    const result = frames.find((f) => f.t === "result") as { value?: mux.WakeItem | null; replayed?: boolean } | undefined
    const head = this.boundEngine?.currentState
    const item = result?.value
    // A chief run locally (mux.configure brain "local") is its host's alone: no second answer from here.
    if (!item || result?.replayed || !head?.agent || !head.owner_user || head.brain !== "cloud") return
    const brain = this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(brainName(head.agent, item.conversation)))
    const wake = { agent: head.agent, owner: head.owner_user, conversation: item.conversation, seq: item.seq, reason: item.reason }
    const failed = (e: unknown) => console.warn(JSON.stringify({ msg: "chief_brain.wake_failed", agent: head.agent, error: String(e).slice(0, 200) }))
    // A Chief whose owner picked the opencode brain (chief-brain-opencode/) is answered there; any other, or one on a
    // deployment without the brain container, goes to the P brain.
    const opencode = this.env.CHIEF_OPENCODE_ENABLED === "1" && this.env.OPENCODE_BRAIN_DO ? this.env.OPENCODE_BRAIN_DO.get(this.env.OPENCODE_BRAIN_DO.idFromName(head.agent)) : undefined
    const first = opencode ? opencode.wake(wake) : Promise.resolve({ skipped: "impl_pi" as string })
    this.ctx.waitUntil(first.then((r) => ("skipped" in r && (r.skipped === "impl_pi" || r.skipped === "no_container") ? brain.wake(wake).then(() => undefined) : undefined)).then(() => undefined, failed))
  }

  /** mux.queue: the head (cursors and pending counts); wake rows come with the snapshot. */
  protected read(head: mux.MuxHead, op: string, _params: unknown, principal: Principal): ReadResult {
    if (!this.allowed(head, principal)) return { ok: false, code: "auth.forbidden", message: "not this chief or its owner" }
    if (op !== "mux.queue") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    return { ok: true, value: head, revision: "" }
  }
}
