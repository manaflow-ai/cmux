import { summary } from "./create.ts"
import type { ConversationReject } from "./reject.ts"
import type { Change, ConversationHead, Message, Op, Participant } from "./types.ts"

/**
 * One op and the stored rows it needs (the Rust `OpRequest`). The host loads
 * `target` for ops that name a message, `reply_target` for a send with
 * `reply_to`, the conversation's last message, and (to enforce the agent
 * budget) the newest BUDGET_WINDOW messages, newest first.
 */
export interface OpRequest {
  readonly actor: string
  readonly idempotency_key: string
  readonly op: Op
  /** RFC 3339 UTC with milliseconds. */
  readonly now: string
  /** The id a `message.send` assigns to its message. */
  readonly new_message_id: string
  readonly target?: Message | null
  readonly reply_target?: Message | null
  readonly last_message?: Message | null
  /** When present, a `message.send` also passes `checkAgentBudget`, after every other rule. */
  readonly recent?: ReadonlyArray<Message> | null
  /**
   * Cloud `invite.accept`: the address ids of the actor's verified addresses,
   * computed by the host (HMAC with the address key). A group email invite
   * binds at once only when its address is in this list.
   */
  readonly actor_addresses?: ReadonlyArray<string> | null
  /**
   * Cloud `participants.add`: the host's participant policy approved this
   * participant (reach rules), and its `owner_user` and `display_name` are the
   * host's, not the caller's. Without it only an agent's owner may add it.
   */
  readonly trusted_participant?: boolean | null
}

/** One committed op: the new head, the message row to upsert, and the change to publish. */
export interface Commit {
  readonly head: ConversationHead
  readonly message?: Message
  readonly change: Change
}

export type ApplyResult = { readonly ok: true; readonly commit: Commit } | ConversationReject

/** Mutable copy of the head that an op edits; `apply` freezes nothing, it only never edits its input. */
export type Draft = { -readonly [K in keyof ConversationHead]: ConversationHead[K] }

/** A participant or metadata change: publish the summary. */
export const conversationChanged = (next: Draft, request: OpRequest): Commit => ({
  head: next,
  change: { kind: "conversation", conversation: summary(next, request.last_message) }
})

/** Replaces the record with the same id in place, or appends. */
export const upsertParticipant = (participants: ReadonlyArray<Participant>, participant: Participant): ReadonlyArray<Participant> =>
  participants.some((existing) => existing.id === participant.id)
    ? participants.map((existing) => (existing.id === participant.id ? participant : existing))
    : [...participants, participant]
