import { fail } from "./reject.ts"
import { conversationChanged, type Commit, type Draft, type OpRequest } from "./request.ts"
import { validateSettings } from "./settings.ts"
import { DEFAULT_SETTINGS, MAX_DISPLAY_NAME_CHARS, type CloudOp, type ConversationHead, type Invite, type Participant } from "./types.ts"
import { charCount, currentParticipant } from "./validate.ts"

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
 * remaining human. A departing contact outside a dm is dropped from the head
 * (nothing refers to it once its invites are closed), so the head stays
 * bounded; a dm keeps its contact peer, which defines the dm.
 */
export const depart = (head: ConversationHead, participants: ReadonlyArray<Participant>, id: string, now: string): ReadonlyArray<Participant> => {
  const leaving = participants.find((participant) => participant.id === id)
  if (leaving?.kind === "contact" && head.kind !== undefined && head.kind !== "dm") return participants.filter((participant) => participant.id !== id)
  let out = participants.map((participant) => (participant.id === id ? { ...participant, role: "member" as const, left_at: now } : participant))
  if (leaving?.role === "owner") {
    const heir = out.find((participant) => participant.kind === "human" && participant.left_at === undefined)
    if (heir) out = out.map((participant) => (participant.id === heir.id ? { ...participant, role: "owner" as const } : participant))
  }
  return out
}

/** No current human left archives a cloud conversation. */
export const archiveIfEmpty = (next: Draft): void => {
  if (!next.participants.some((participant) => participant.kind === "human" && participant.left_at === undefined)) next.state = "archived"
}

/** An invite that can still be accepted or approved. */
export const isOpen = (invite: Invite): boolean => invite.status === "pending" || invite.status === "pending_approval"

/** `participants.remove`: leave (self), remove (conversation owner), or remove a chief (its owner). */
export const removeParticipant = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, op: OpOf<"participants.remove">): Commit => {
  if (head.kind === "dm" || head.kind === "chief") fail("kind_forbids")
  const target = currentParticipant(head, op.participant)
  if (!target) return fail("unknown_participant")
  const allowed = target.id === actor.id || actor.role === "owner" || (target.kind === "agent" && target.owner_user === actor.id)
  if (!allowed) fail("forbidden")
  next.participants = depart(head, head.participants, target.id, request.now)
  // A removed contact cannot accept: its pending invites end with it.
  if (target.kind === "contact" && head.invites) {
    next.invites = head.invites.map((invite) => (invite.contact === target.id && isOpen(invite) ? { ...invite, status: "revoked" as const } : invite))
  }
  if (head.kind !== undefined) archiveIfEmpty(next)
  next.updated_at = request.now
  return conversationChanged(next, request)
}

/** `conversation.settings.set`: the conversation owner only. */
export const setSettings = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, op: OpOf<"conversation.settings.set">): Commit => {
  if (actor.role !== "owner") fail("forbidden")
  const { kind: _kind, ...patch } = op
  next.settings = validateSettings(head.settings ?? DEFAULT_SETTINGS, patch, true)
  return conversationChanged(next, request)
}
