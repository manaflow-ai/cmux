import { checkAgentBudget, checkAgentStreak } from "./budget.ts"
import { removeParticipant, setSettings } from "./cloud.ts"
import { acceptInvite, approveJoin, createInvite, reportDelivery, revokeInvite } from "./invite-ops.ts"
import { parseRfc3339Millis, validToken } from "./ids.ts"
import { fail, reject, RejectError } from "./reject.ts"
import { conversationChanged, upsertParticipant, type ApplyResult, type Commit, type Draft, type OpRequest } from "./request.ts"
import {
  MAX_PARTICIPANTS,
  SYSTEM_ACTOR,
  type ConversationHead,
  type Message,
  type Op,
  type Participant
} from "./types.ts"
import {
  currentParticipant,
  currentParticipants,
  findParticipant,
  hasText,
  reactionEquals,
  validateParticipant,
  validateParts,
  validateReaction,
  validateTitle
} from "./validate.ts"

/** The message an op changes, which the host loads. */
export const targetMessageId = (op: Op): string | undefined =>
  op.kind === "message.edit" || op.kind === "message.retract" || op.kind === "reaction.add" || op.kind === "reaction.remove"
    ? op.message_id
    : undefined

export const isSend = (op: Op): boolean => op.kind === "message.send"

const CLOUD_OPS = new Set(["invite.create", "invite.revoke", "invite.accept", "invite.approve_join", "invite.delivery.report", "conversation.settings.set"])

/** Validates one op against the head. Every commit increases `rev` by exactly one. */
export const apply = (head: ConversationHead, request: OpRequest): ApplyResult => {
  try {
    return { ok: true, commit: applyOrThrow(head, request) }
  } catch (error) {
    if (error instanceof RejectError) return reject(error.code)
    throw error
  }
}

const applyOrThrow = (head: ConversationHead, request: OpRequest): Commit => {
  const op = request.op
  if (typeof op !== "object" || op === null) return fail("unsupported_op")
  const cloud = head.kind !== undefined
  if (CLOUD_OPS.has(op.kind) && !cloud) fail("unsupported_op")
  const next: Draft = { ...head, rev: head.rev + 1 }
  // Ops whose caller is not a participant.
  if (op.kind === "invite.accept") return acceptInvite(head, next, request, op)
  if (op.kind === "invite.delivery.report") {
    if (request.actor !== SYSTEM_ACTOR) fail("forbidden")
    return reportDelivery(head, next, request, op)
  }
  const actor = currentParticipant(head, request.actor)
  if (!actor) return fail("not_participant")
  if (actor.kind === "address") fail("address_cannot_act")
  if (head.state === "archived") fail("archived")
  const now = request.now
  switch (op.kind) {
    case "message.send": {
      if (op.client_msg_id !== request.idempotency_key || !validToken(op.client_msg_id)) fail("invalid_client_msg_id")
      const parts = validateParts(op.parts)
      const replyTo = op.reply_to
      if (replyTo !== undefined) {
        const replied = request.reply_target
        if (!replied || replied.id !== replyTo.message_id || replied.conversation !== head.id) fail("unknown_message")
        if (replyTo.part_index >= replied!.parts.length) fail("invalid_part_index")
      }
      const nowMs = parseRfc3339Millis(now) ?? 0
      // Cloud heads carry the loop guard; local heads use the Rust row window when the host passes it.
      const budget = cloud ? checkAgentStreak(head, request.actor, parts, nowMs) : request.recent ? checkAgentBudget(head, request.actor, parts, request.recent, nowMs) : null
      if (budget) fail(budget)
      next.last_seq = head.last_seq + 1
      next.updated_at = now
      if (cloud && hasText(parts)) {
        if (actor.kind === "agent") {
          next.agent_text_streak = (head.agent_text_streak ?? 0) + 1
          next.last_agent_text_at = now
        } else {
          next.agent_text_streak = 0
        }
      }
      const message: Message = {
        id: request.new_message_id,
        conversation: head.id,
        seq: next.last_seq,
        client_msg_id: op.client_msg_id,
        author: request.actor,
        parts,
        ...(replyTo === undefined ? {} : { reply_to: { message_id: replyTo.message_id, part_index: replyTo.part_index } }),
        created_at: now,
        reactions: []
      }
      return { head: next, message, change: { kind: "message", message } }
    }
    // Edits, retractions and reactions change a message, not the list order,
    // so `updated_at` stays.
    case "message.edit": {
      const message = target(head, request, op.message_id)
      if (message.author !== request.actor) fail("not_author")
      if (message.retracted_at !== undefined) fail("retracted")
      const parts = validateParts(op.parts)
      return updated(next, {
        ...message,
        parts,
        edited_at: now,
        reactions: message.reactions.filter((reaction) => reaction.part_index < parts.length)
      })
    }
    case "message.retract": {
      const message = target(head, request, op.message_id)
      if (message.author !== request.actor) fail("not_author")
      if (message.retracted_at !== undefined) fail("retracted")
      return updated(next, { ...message, parts: [], reactions: [], retracted_at: now })
    }
    case "reaction.add": {
      const message = target(head, request, op.message_id)
      if (message.retracted_at !== undefined) fail("retracted")
      if (op.part_index >= message.parts.length) fail("invalid_part_index")
      const kind = validateReaction(op.reaction)
      const same = (reaction: Message["reactions"][number]) =>
        reaction.author === request.actor && reaction.part_index === op.part_index && reactionEquals(reaction.kind, kind)
      if (message.reactions.some(same)) fail("duplicate_reaction")
      return updated(next, { ...message, reactions: [...message.reactions, { author: request.actor, part_index: op.part_index, kind, at: now }] })
    }
    case "reaction.remove": {
      const message = target(head, request, op.message_id)
      if (message.retracted_at !== undefined) fail("retracted")
      const position = message.reactions.findIndex(
        (reaction) => reaction.author === request.actor && reaction.part_index === op.part_index && reactionEquals(reaction.kind, op.reaction)
      )
      if (position < 0) fail("unknown_reaction")
      return updated(next, { ...message, reactions: message.reactions.filter((_, index) => index !== position) })
    }
    case "read_cursor.set": {
      if (!Number.isInteger(op.seq) || op.seq < 0 || op.seq > head.last_seq) fail("cursor_out_of_range")
      if (op.seq < (head.read_cursors[request.actor] ?? 0)) fail("cursor_regression")
      // Reading does not reorder the conversation list, so `updated_at` stays.
      next.read_cursors = sortedRecord({ ...head.read_cursors, [request.actor]: op.seq })
      return { head: next, change: { kind: "read-cursor", participant: request.actor, seq: op.seq } }
    }
    case "participants.add": {
      if (head.kind === "dm" || head.kind === "chief") fail("kind_forbids")
      const participant = validateParticipant(op.participant, cloud)
      if (participant.kind === "address") fail("invalid_participant")
      if (currentParticipant(head, participant.id)) fail("duplicate_participant")
      // A departed participant (cloud only) rejoins; locally every id is current.
      if (!cloud && findParticipant(head, participant.id)) fail("duplicate_participant")
      if (currentParticipants(head).length >= MAX_PARTICIPANTS) fail("invalid_participant")
      let stamped: Participant = participant
      if (cloud) {
        // A known (departed) record's owner is trusted; a caller-supplied one only with the host's approval.
        const owner = findParticipant(head, participant.id)?.owner_user ?? participant.owner_user
        if (participant.kind === "agent" && owner !== request.actor && request.trusted_participant !== true) fail("forbidden")
        stamped = { ...participant, ...(owner === undefined ? {} : { owner_user: owner }), role: "member", joined_seq: head.last_seq, added_by: request.actor }
      }
      next.participants = upsertParticipant(head.participants, stamped)
      next.updated_at = now
      return conversationChanged(next, request)
    }
    case "title.set": {
      if (head.kind === "dm" || head.kind === "chief") fail("kind_forbids")
      validateTitle(op.title)
      next.title = op.title
      next.updated_at = now
      return conversationChanged(next, request)
    }
    case "participants.remove":
      return removeParticipant(head, next, request, actor, op)
    case "invite.create":
      return createInvite(head, next, request, actor, op)
    case "invite.revoke":
      return revokeInvite(head, next, request, actor, op)
    case "invite.approve_join":
      return approveJoin(head, next, request, actor, op)
    case "conversation.settings.set":
      return setSettings(head, next, request, actor, op)
    default:
      return fail("unsupported_op")
  }
}

const target = (head: ConversationHead, request: OpRequest, messageId: string): Message => {
  const message = request.target
  if (!message || message.id !== messageId || message.conversation !== head.id) return fail("unknown_message")
  return message
}

const updated = (next: Draft, message: Message): Commit => {
  const clean = { ...message }
  return { head: next, message: clean, change: { kind: "message-updated", message: clean } }
}

/** Keys in code-unit order, as the Rust `BTreeMap` serializes them. */
const sortedRecord = (record: Readonly<Record<string, number>>): Record<string, number> =>
  Object.fromEntries(Object.entries(record).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
