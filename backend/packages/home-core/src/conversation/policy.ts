import type { Principal } from "./engine-types.ts"
import { SYSTEM_ACTOR, type ConversationHead, type Participant } from "./types.ts"
import { safeDisplayName } from "./validate.ts"

/**
 * Who may be put into a conversation, and with which trusted fields
 * (home-messaging.md section 4.1 `participants.add`). The ConversationDO
 * injects a policy that knows the reach rules (shared teams, chief
 * `reachability`, owner records); the Domain stamps `owner_user` and
 * `display_name` from the decision and ignores the caller's values.
 */
export type ParticipantDecision =
  | { readonly ok: true; readonly owner_user?: string; readonly display_name: string }
  | { readonly ok: false; readonly code: string }

export type ParticipantPolicy = (principal: Principal, participant: Participant, head: ConversationHead | null) => ParticipantDecision

/** Fallback when a name from Stack or the caller is empty after cleaning. */
export const FALLBACK_NAME = "Member"

const prefixed = (prefix: string, id: string) => (id.startsWith(prefix) ? id : `${prefix}${id}`)

/** The actor id from the authenticated principal, never from params. */
export const actorOf = (principal: Principal): string | null => {
  if (principal.kind === "system") return SYSTEM_ACTOR
  if (principal.agent) return prefixed("agent_", principal.agent)
  if (principal.user) return prefixed("user_", principal.user)
  return null
}

/**
 * The rules that need no outside data: the caller themself (name from the
 * principal); a contact (its id comes from `contact.ensure` in the Worker); a
 * former participant of this conversation (its stored record is trusted); a
 * departed agent only when the caller is its stored owner. Everyone else is
 * refused: an injected policy decides those.
 */
export const defaultParticipantPolicy: ParticipantPolicy = (principal, participant, head) => {
  const actor = actorOf(principal)
  const known = head?.participants.find((candidate) => candidate.id === participant.id)
  if (participant.kind === "contact") return { ok: true, display_name: safeDisplayName(participant.display_name, FALLBACK_NAME) }
  if (participant.kind === "agent") {
    if (known?.owner_user !== undefined && known.owner_user === actor) return { ok: true, owner_user: known.owner_user, display_name: known.display_name }
    return { ok: false, code: "forbidden" }
  }
  if (participant.id === actor) return { ok: true, display_name: safeDisplayName(principal.display_name, FALLBACK_NAME) }
  if (known) return { ok: true, display_name: known.display_name }
  return { ok: false, code: "forbidden" }
}

/** Applies a decision: trusted `owner_user` and `display_name`, nothing from the caller. */
export const stampParticipant = (participant: Participant, decision: ParticipantDecision & { ok: true }): Participant => {
  const { owner_user: _owner, display_name: _name, ...rest } = participant
  return { ...rest, display_name: decision.display_name, ...(decision.owner_user === undefined ? {} : { owner_user: decision.owner_user }) }
}
