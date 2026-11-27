import { makeConversationDomain, type ConversationParams, type ConversationState } from "../../src/conversation/domain.ts"
import type { OutboxItem, Principal, ReduceResult } from "../../src/conversation/engine-types.ts"
import type { ParticipantPolicy } from "../../src/conversation/policy.ts"
import type { Participant } from "../../src/conversation/types.ts"
import { DomainHost } from "./harness.ts"

/**
 * A cloud group on the real ConversationDO domain, for the role, revoke and scale tests
 * (plans/cmux-next/home-dm-group-chats/DESIGN.md). Every person may reach every other person
 * (the Worker's reach rule is tested in apps/api), so the tests see only the group's own rules.
 */
export const reachEveryone: ParticipantPolicy = (_principal, participant) => ({ ok: true, display_name: participant.display_name || "Member" })

export const person = (n: number | string): Participant => ({ id: `user_${n}`, kind: "human", display_name: `Person ${n}` })
export const as = (id: string): Principal => ({ kind: "session", identity: id, user: id, display_name: id })

export class Group {
  readonly host = new DomainHost<ConversationState, ConversationParams>(makeConversationDomain({ participantPolicy: reachEveryone }))
  private keys = 0
  readonly id = "conv_GROUPSCALE"

  constructor(owner: string, members: ReadonlyArray<string>, title = "Trip") {
    const made = this.host.run(as(owner), "conversation.create", { id: this.id, title, participants: [owner, ...members].map((id) => ({ id, kind: "human", display_name: id })) }, this.key())
    if (!made.ok) throw new Error(`create: ${made.code}`)
  }

  key(): string {
    return `k${++this.keys}`
  }

  run(actor: string, op: string, params: Record<string, unknown> = {}): ReduceResult<ConversationState> {
    return this.host.run(as(actor), op, params, op === "message.send" ? String(params.client_msg_id) : this.key())
  }

  /** The reject code, or "ok". */
  code(actor: string, op: string, params: Record<string, unknown> = {}): string {
    const result = this.run(actor, op, params)
    return result.ok ? "ok" : result.code
  }

  send(actor: string, text: string, mentions: ReadonlyArray<string> = []): ReduceResult<ConversationState> {
    const key = this.key()
    // One "@" per mention ahead of the text, each run on its own character.
    const runs = mentions.map((mention, start) => ({ start, length: 1, mention }))
    return this.run(actor, "message.send", { client_msg_id: key, parts: [{ type: "text", text: "@".repeat(mentions.length) + text, ...(runs.length ? { runs } : {}) }] })
  }

  add(actor: string, id: string, role?: string): string {
    return this.code(actor, "participants.add", { participant: { id, kind: "human", display_name: id }, ...(role ? { role } : {}) })
  }

  /** The outbox items one call appended. */
  outboxOf(run: () => unknown): ReadonlyArray<OutboxItem> {
    const before = this.host.outbox.length
    run()
    return this.host.outbox.slice(before)
  }

  get stateBytes(): number {
    return JSON.stringify(this.host.state).length
  }
}
