import type { Domain, Principal } from "@cmux/ownership"
import { mux } from "@cmux/home-core"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { publicActor } from "./public-actor.ts"

/**
 * MuxDO, one per chief (home-messaging.md sections 3 and 4.3): the chief's wake queue, run by
 * lane 15's pure domain in row mode (wake rows, so an offline week stays bounded). The brain
 * host subscribes to `mux:<agent>` and acks with mux.ack; ConversationDO outboxes send mux.wake.
 */
export class MuxDO extends OwnerDO<mux.MuxHead> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, mux.muxDomain as Domain<mux.MuxHead>, "mux", publicActor, {
      rowMode: { snapshotTable: mux.TABLE_WAKE, snapshotTail: 200 }
    })
  }

  /** The chief itself (agent token) or its owner. */
  private allowed(head: mux.MuxHead, p: Principal): boolean {
    if (p.kind === "agent") return p.agent !== undefined && p.agent === head.agent
    return (p.kind === "session" || p.kind === "install") && p.user !== undefined && p.user === head.owner_user
  }

  protected maySubscribe(head: mux.MuxHead, principal: Principal): boolean {
    return this.allowed(head, principal)
  }

  /** mux.queue: the head (cursors and pending counts); wake rows come with the snapshot. */
  protected read(head: mux.MuxHead, op: string, _params: unknown, principal: Principal): ReadResult {
    if (!this.allowed(head, principal)) return { ok: false, code: "auth.forbidden", message: "not this chief or its owner" }
    if (op !== "mux.queue") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    return { ok: true, value: head, revision: "" }
  }
}
