import { fail } from "./reject.ts"
import { conversationChanged, type Commit, type Draft, type OpRequest } from "./request.ts"
import { validateSettings } from "./settings.ts"
import { DEFAULT_SETTINGS, MAX_DISPLAY_NAME_CHARS, type CloudOp, type ConversationHead, type Invite, type Message, type Participant, type ParticipantRole } from "./types.ts"
import { checkGrant, checkOver, grantableRole, isManager, roleOf } from "./roles.ts"
import { charCount, currentParticipant, findParticipant } from "./validate.ts"

/**
 * Cloud extensions of the reducer (home-messaging.md section 4.1): leave and
 * remove, and settings. Invite ops are in invite-ops.ts. Each function
 * receives the head, a draft at `rev + 1` and the validated actor, and returns
 * the commit or throws a reject.
 */

export type OpOf<K extends CloudOp["kind"]> = Extract<CloudOp, { kind: K }>

export const validName = (name: unknown): boolean =>
  typeof name === "string" && charCount(name) > 0 && charCount(name) <= MAX_DISPLAY_NAME_CHARS && !/\p{Cc}/u.test(name)

/**
 * Departs a participant; an owner who leaves hands the role to the earliest
 * remaining human. A departing address outside a dm is dropped from the head
 * (nothing refers to it once its invites are closed), so the head stays
 * bounded; a dm keeps its address peer, which defines the dm.
 */
export const depart = (head: ConversationHead, participants: ReadonlyArray<Participant>, id: string, now: string): ReadonlyArray<Participant> => {
  const leaving = participants.find((participant) => participant.id === id)
  if (leaving?.kind === "address" && head.kind !== undefined && head.kind !== "dm") return participants.filter((participant) => participant.id !== id)
  let out = participants.map((participant) => (participant.id === id ? { ...participant, role: "member" as const, left_at: now } : participant))
  if (leaving?.role === "owner") {
    // The earliest remaining admin, else the earliest remaining human.
    const remaining = out.filter((participant) => participant.kind === "human" && participant.left_at === undefined)
    const heir = remaining.find((participant) => participant.role === "admin") ?? remaining.find((participant) => participant.role !== "read_only") ?? remaining[0]
    if (heir) out = out.map((participant) => (participant.id === heir.id ? { ...participant, role: "owner" as const } : participant))
  }
  return out
}

/** No current human left archives a cloud conversation. */
export const archiveIfEmpty = (next: Draft): void => {
  // A large group counts its rows: large.ts settle archives it.
  if (next.tier === "large") return
  if (!next.participants.some((participant) => participant.kind === "human" && participant.left_at === undefined)) next.state = "archived"
}

/** An invite that can still be accepted or approved. */
export const isOpen = (invite: Invite): boolean => invite.status === "pending" || invite.status === "pending_approval"

/**
 * `participants.remove`: leave (self), remove someone below you (an admin or the owner, roles.ts),
 * or remove a chief (its owner). `ban` (managers only, never yourself) keeps the person out: the
 * host writes the ban row (domain.ts) and refuses adds until `participants.unban`.
 */
export const removeParticipant = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, op: OpOf<"participants.remove">): Commit => {
  if (head.kind === "dm") fail("kind_forbids")
  const target = currentParticipant(head, op.participant)
  if (!target) return fail("unknown_participant")
  // A Chief's conversation keeps its owner and its Chief; only the people it was shared with leave or are removed.
  if (head.kind === "chief" && (target.kind !== "human" || roleOf(target) === "owner")) fail("kind_forbids")
  // A Chief's conversation has no ban list to manage (no unban there): the owner just removes.
  if (head.kind === "chief" && op.ban === true) fail("kind_forbids")
  const self = target.id === actor.id
  const ownChief = target.kind === "agent" && target.owner_user === actor.id
  if (!self && !ownChief) checkOver(actor, target)
  if (op.ban === true && (self || !isManager(actor))) fail("forbidden")
  next.participants = depart(head, head.participants, target.id, request.now)
  // A removed address cannot accept: its pending invites end with it.
  if (target.kind === "address" && head.invites) {
    next.invites = head.invites.map((invite) => (invite.address === target.id && isOpen(invite) ? { ...invite, status: "revoked" as const } : invite))
  }
  if (head.kind !== undefined) archiveIfEmpty(next)
  next.updated_at = request.now
  return conversationChanged(next, request)
}

/**
 * A Chief's conversation shared with teammates (cmux#25569): its owner adds people (never an agent:
 * the conversation has one Chief), as members who talk to the Chief or read-only people who only see
 * it. Nobody else adds anyone, and nobody becomes an admin. The Worker resolves the reach (a shared
 * team only, domain.ts). The Chief keeps its owner's grants: a teammate's request to it gets the
 * approval rule (chief-brain effect-policy.ts), and only the owner answers its questions.
 */
export const checkChiefShare = (actor: Participant, participant: Participant, role: ParticipantRole | undefined): void => {
  if (participant.kind !== "human") fail("invalid_participant")
  if (roleOf(actor) !== "owner") fail("forbidden")
  if (role !== undefined && role !== "member" && role !== "read_only") fail("forbidden")
}

/** In a Chief's conversation an agent's question is its owner's to answer (an approval), not a teammate's. */
export const checkChiefAnswer = (head: ConversationHead, question: Message, actor: Participant): void => {
  if (head.kind !== "chief") return
  const asker = findParticipant(head, question.author)
  if (asker?.kind === "agent" && asker.owner_user !== actor.id) fail("forbidden")
}

/** `participants.set_role`: a manager strictly above the target sets a role it may grant. */
export const setRole = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, op: OpOf<"participants.set_role">): Commit => {
  if (head.kind === "dm") fail("kind_forbids")
  const role = grantableRole(op.role)
  // In a Chief's conversation only its owner manages: a teammate is a member (talks) or read-only (sees).
  if (head.kind === "chief" && (roleOf(actor) !== "owner" || role === "admin")) fail("forbidden")
  const target = currentParticipant(head, op.participant)
  if (!target) return fail("unknown_participant")
  if (target.kind !== "human") fail("invalid_participant")
  checkOver(actor, target)
  checkGrant(actor, role)
  if (roleOf(target) === role) return conversationChanged(next, request)
  next.participants = head.participants.map((participant) => (participant.id === target.id ? { ...participant, role } : participant))
  return conversationChanged(next, request)
}

/** `ownership.transfer`: the owner hands the conversation to a current human and becomes an admin. */
export const transferOwnership = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, op: OpOf<"ownership.transfer">): Commit => {
  if (head.kind === "dm" || head.kind === "chief") fail("kind_forbids")
  if (roleOf(actor) !== "owner") fail("forbidden")
  const target = currentParticipant(head, op.participant)
  if (!target) return fail("unknown_participant")
  if (target.kind !== "human" || target.id === actor.id) fail("invalid_participant")
  next.participants = head.participants.map((participant) =>
    participant.id === target.id ? { ...participant, role: "owner" as const } : participant.id === actor.id ? { ...participant, role: "admin" as const } : participant
  )
  return conversationChanged(next, request)
}

/** `participants.unban`: a manager lifts a ban; the host deletes the ban row (domain.ts). */
export const unban = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, _op: OpOf<"participants.unban">): Commit => {
  if (head.kind === "dm" || head.kind === "chief") fail("kind_forbids")
  if (!isManager(actor)) fail("forbidden")
  return conversationChanged(next, request)
}

/** `conversation.settings.set`: the conversation owner only. */
export const setSettings = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, op: OpOf<"conversation.settings.set">): Commit => {
  if (actor.role !== "owner") fail("forbidden")
  const { kind: _kind, ...patch } = op
  next.settings = validateSettings(head.settings ?? DEFAULT_SETTINGS, patch, true)
  return conversationChanged(next, request)
}
