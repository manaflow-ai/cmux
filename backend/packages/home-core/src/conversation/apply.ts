import { checkAgentBudget, checkAgentStreak, threadAgentStreak, withTurn } from "./budget.ts"
import { checkChiefAnswer, checkChiefShare, removeParticipant, setRole, setSettings, transferOwnership, unban } from "./cloud.ts"
import { checkGrant, checkWriter, grantableRole } from "./roles.ts"
import { MAX_GROUP_MEMBERS, memberCount } from "./large.ts"
import { createGrant, revokeGrant } from "./grants.ts"
import { acceptInvite, acceptVerifiedInvite, approveJoin, createInvite, reportDelivery, revokeInvite } from "./invite-ops.ts"
import { parseRfc3339Millis, validToken } from "./ids.ts"
import { answerQuestion, checkQuestionEdit } from "./question.ts"
import { fail, reject, RejectError } from "./reject.ts"
import { conversationChanged, upsertParticipant, type ApplyResult, type Commit, type Draft, type OpRequest } from "./request.ts"
import {
  DEFAULT_SETTINGS,
  MAX_PARTICIPANTS,
  SYSTEM_ACTOR,
  type ThreadResolution,
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
  validateThreadTitle,
  validateTitle
} from "./validate.ts"

/** The message an op changes, which the host loads. */
export const targetMessageId = (op: Op): string | undefined =>
  op.kind === "message.edit" || op.kind === "message.retract" || op.kind === "reaction.add" || op.kind === "reaction.remove" || op.kind === "question.answer"
    ? op.message_id
    : op.kind === "thread.update"
      ? op.root
      : undefined

export const isSend = (op: Op): boolean => op.kind === "message.send"

const CLOUD_OPS = new Set(["invite.create", "invite.revoke", "invite.accept", "invite.accept_verified", "invite.approve_join", "invite.delivery.report", "chief.rename", "conversation.settings.set", "participants.set_role", "ownership.transfer", "participants.unban", "grant.create", "grant.revoke"])

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
  if (op.kind === "invite.accept_verified") return acceptVerifiedInvite(head, next, request, op)
  if (op.kind === "invite.delivery.report") {
    if (request.actor !== SYSTEM_ACTOR) fail("forbidden")
    return reportDelivery(head, next, request, op)
  }
  if (op.kind === "chief.rename") {
    if (request.actor !== SYSTEM_ACTOR) fail("forbidden")
    return renameChief(head, next, request, op)
  }
  const actor = currentParticipant(head, request.actor)
  if (!actor) return fail("not_participant")
  if (actor.kind === "address") fail("address_cannot_act")
  if (head.state === "archived") fail("archived")
  // A promoted conversation opens for normal ops only after `conversation.import.commit`.
  if (head.state === "importing") fail("importing")
  // Roles are cloud only: a local head has no read-only members.
  if (cloud) checkWriter(actor, op.kind, op.kind === "participants.remove" ? op.participant : undefined)
  const now = request.now
  switch (op.kind) {
    case "message.send": {
      if (op.client_msg_id !== request.idempotency_key || !validToken(op.client_msg_id)) fail("invalid_client_msg_id")
      const parts = validateParts(op.parts, cloud, true)
      // Only an agent posts a question, and only a pending one (Rust `bad_question`).
      if (parts.some((part) => part.type === "question" && (actor.kind !== "agent" || part.state.kind !== "pending"))) fail("invalid_parts")
      const replyTo = op.reply_to
      let parent: Message | undefined
      if (replyTo !== undefined) {
        const replied = request.reply_target
        if (!replied || replied.id !== replyTo.message_id || replied.conversation !== head.id) fail("unknown_message")
        if (replyTo.part_index >= replied!.parts.length) fail("invalid_part_index")
        parent = replied!
      }
      // A null thread_root is no thread (as serde reads it in Rust).
      const namedRoot = op.thread_root ?? undefined
      if (namedRoot !== undefined) {
        const root = request.thread_target
        // thread_root is always the top root: a reply in a thread cannot be a root (Rust `InvalidThreadRoot`).
        if (!root || root.id !== namedRoot || root.conversation !== head.id || root.thread_root !== undefined) fail("invalid_thread_root")
      }
      // Threads nest without a limit (conversation-tree-v1, Rust reducer.rs): reply_to is the parent;
      // a parent in a thread passes its root on; a named root must be the parent's own.
      if (namedRoot !== undefined && parent !== undefined && parent.id !== namedRoot && parent.thread_root !== namedRoot) fail("invalid_thread_root")
      const threadRoot = namedRoot ?? parent?.thread_root
      const nowMs = parseRfc3339Millis(now) ?? 0
      // Every head carries the loop guard (O(1), no row window, so work cards cannot hide agent
      // turns). A head written before the counters existed falls back to the row window once.
      const counted = head.agent_text_streak !== undefined
      const budget = counted || cloud ? checkAgentStreak(head, request.actor, parts, nowMs, threadRoot) : request.recent ? checkAgentBudget(head, request.actor, parts, request.recent, nowMs, threadRoot) : null
      if (budget) fail(budget)
      next.last_seq = head.last_seq + 1
      next.updated_at = now
      if (hasText(parts)) {
        // The streak of the thread this message joins: an agent's text adds 1, a person's resets it.
        // A legacy head (no counters yet) seeds it from the host window's trailing agent texts.
        const seed = actor.kind === "agent" && !(counted || cloud) && request.recent ? threadAgentStreak(head, request.recent, threadRoot) : undefined
        applyTurn(next, withTurn(next, threadRoot, actor.kind === "agent", now, seed))
      }
      const message: Message = {
        id: request.new_message_id,
        conversation: head.id,
        seq: next.last_seq,
        client_msg_id: op.client_msg_id,
        author: request.actor,
        parts,
        ...(replyTo === undefined ? {} : { reply_to: { message_id: replyTo.message_id, part_index: replyTo.part_index } }),
        ...(threadRoot === undefined ? {} : { thread_root: threadRoot }),
        created_at: now,
        reactions: []
      }
      // A sender that had read everything before its send has read its own message too, for
      // every client of this owner. One that had not keeps its cursor, so a message it never
      // read (an agent's unhandled turn, a channel message behind a thread reply) stays unread.
      // The change stays `message`; clients read the cursor from the head.
      if ((head.read_cursors[request.actor] ?? 0) >= head.last_seq) next.read_cursors = sortedRecord({ ...head.read_cursors, [request.actor]: next.last_seq })
      return { head: next, message, change: { kind: "message", message } }
    }
    // Edits, retractions and reactions change a message, not the list order,
    // so `updated_at` stays.
    case "message.edit": {
      const message = target(head, request, op.message_id)
      if (message.author !== request.actor) fail("not_author")
      if (message.retracted_at !== undefined) fail("retracted")
      const parts = validateParts(op.parts, cloud, true)
      checkQuestionEdit(message.parts, parts)
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
    case "question.answer": {
      const message = target(head, request, op.message_id)
      if (message.retracted_at !== undefined) fail("retracted")
      const index = op.part_index
      const part = Number.isInteger(index) && index >= 0 && index <= 0xffff_ffff ? message.parts[index] : undefined
      if (part?.type !== "question") return fail("invalid_part_index")
      const answered = answerQuestion(part, op.answer, actor, now)
      if (cloud) checkChiefAnswer(head, message, actor)
      // A person's answer (question answers are human only) is a person's turn in the question's
      // thread: agents may go on there (the loop guard counts from here).
      applyTurn(next, withTurn(next, message.thread_root, false, now))
      return updated(next, { ...message, parts: message.parts.map((p, i) => (i === index ? answered : p)) })
    }
    case "read_cursor.set": {
      if (!Number.isInteger(op.seq) || op.seq < 0 || op.seq > head.last_seq) fail("cursor_out_of_range")
      if (op.seq < (head.read_cursors[request.actor] ?? 0)) fail("cursor_regression")
      // Reading does not reorder the conversation list, so `updated_at` stays.
      next.read_cursors = sortedRecord({ ...head.read_cursors, [request.actor]: op.seq })
      return { head: next, change: { kind: "read-cursor", participant: request.actor, seq: op.seq } }
    }
    case "participants.add": {
      if (head.kind === "dm") fail("kind_forbids")
      const participant = validateParticipant(op.participant, cloud)
      if (participant.kind === "address") fail("invalid_participant")
      if (head.kind === "chief") checkChiefShare(actor, participant, op.role)
      if (currentParticipant(head, participant.id)) fail("duplicate_participant")
      // A departed participant (cloud only) rejoins; locally every id is current.
      if (!cloud && findParticipant(head, participant.id)) fail("duplicate_participant")
      // A local head keeps the Rust cap; a cloud group grows into the large tier (large.ts). A shared
      // Chief conversation stays small (a team around one Chief), under the local cap.
      if (cloud && head.kind !== "chief" ? memberCount(head) >= MAX_GROUP_MEMBERS : currentParticipants(head).length >= MAX_PARTICIPANTS) fail("invalid_participant")
      let stamped: Participant = participant
      if (cloud) {
        if (request.banned === true) fail("banned")
        const role = op.role === undefined ? "member" : grantableRole(op.role)
        checkGrant(actor, role)
        // A known (departed) record's owner is trusted; a caller-supplied one only with the host's approval.
        const owner = findParticipant(head, participant.id)?.owner_user ?? participant.owner_user
        if (participant.kind === "agent" && owner !== request.actor && request.trusted_participant !== true) fail("forbidden")
        stamped = { ...participant, ...(owner === undefined ? {} : { owner_user: owner }), role, joined_seq: head.last_seq, added_by: request.actor }
      }
      // The first share of a Chief's conversation shows teammates what comes next, not the owner's earlier
      // one-to-one history (the owner may open it with conversation.settings.set history_visible all).
      if (head.kind === "chief" && !head.participants.some((p) => p.kind === "human" && p.id !== actor.id)) {
        next.settings = { ...(head.settings ?? DEFAULT_SETTINGS), history_visible: "since_join" }
      }
      next.participants = upsertParticipant(head.participants, stamped)
      next.updated_at = now
      return conversationChanged(next, request)
    }
    // A thread object lives on its root (conversation-thread-objects-v1). Like an edit it changes
    // a message, not the list order, so `updated_at` stays; any participant may set it, a Chief too.
    case "thread.update": {
      const message = target(head, request, op.root)
      if (message.thread_root !== undefined) fail("invalid_thread_root")
      // A null field is absent, as serde reads it in Rust.
      const title = op.title ?? undefined
      const status = op.status ?? undefined
      const owner = op.owner ?? undefined
      if (title === undefined && status === undefined && owner === undefined) fail("invalid_thread_update")
      const state: { title?: string; owner?: string; resolved?: ThreadResolution } = { ...message.thread }
      if (title !== undefined) {
        // An empty title clears it (readers show the root's first line).
        validateThreadTitle(title)
        if (title === "") delete state.title
        else state.title = title
      }
      if (owner !== undefined) {
        // A current participant who can act: a person, a device or an agent (a Chief), never a
        // pending invited address.
        const holder = owner === "" ? undefined : currentParticipant(head, owner as string)
        if (typeof owner !== "string" || (owner !== "" && (!holder || holder.kind === "address"))) fail("invalid_thread_owner")
        if (owner === "") delete state.owner
        else state.owner = owner
      }
      if (status === "resolved") state.resolved = { by: request.actor, at: now, seq: head.last_seq }
      else if (status === "open") delete state.resolved
      else if (status !== undefined) fail("invalid_thread_update")
      const { thread: _old, ...rest } = message
      const empty = state.title === undefined && state.owner === undefined && state.resolved === undefined
      return updated(next, empty ? rest : { ...rest, thread: state })
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
    case "participants.set_role":
      return setRole(head, next, request, actor, op)
    case "ownership.transfer":
      return transferOwnership(head, next, request, actor, op)
    case "participants.unban":
      return unban(head, next, request, actor, op)
    case "grant.create":
      return createGrant(head, next, request, actor, op)
    case "grant.revoke":
      return revokeGrant(head, next, request, actor, op)
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

/** Copies the loop-guard fields of `turned` (`withTurn`) onto the draft head. */
const applyTurn = (next: Draft, turned: ConversationHead): void => {
  const draft = next as { agent_text_streak?: number; last_agent_text_at?: string; thread_agent_streaks?: Readonly<Record<string, number>> }
  if (turned.agent_text_streak !== undefined) draft.agent_text_streak = turned.agent_text_streak
  if (turned.last_agent_text_at !== undefined) draft.last_agent_text_at = turned.last_agent_text_at
  if (turned.thread_agent_streaks === undefined) delete draft.thread_agent_streaks
  else draft.thread_agent_streaks = turned.thread_agent_streaks
}

/**
 * `chief.rename` (system, from the owner's UserDO): the Chief's conversation shows the Chief's new
 * name, as its title and on the Chief's own participant record. Only a Chief's conversation, only
 * its own Chief; `title.set` stays refused there, so the record in UserDO is the one source.
 */
const renameChief = (head: ConversationHead, next: Draft, request: OpRequest, op: Extract<Op, { kind: "chief.rename" }>): Commit => {
  if (head.kind !== "chief") fail("kind_forbids")
  const chief = currentParticipant(head, op.chief)
  if (!chief || chief.kind !== "agent") fail("unknown_participant")
  validateTitle(op.display_name)
  const renamed = validateParticipant({ ...chief, display_name: op.display_name }, true)
  next.title = op.display_name
  next.participants = upsertParticipant(head.participants, { ...chief, ...renamed })
  next.updated_at = request.now
  return conversationChanged(next, request)
}
