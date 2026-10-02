import { depart, isOpen, validName, type OpOf } from "./cloud.ts"
import { formatRfc3339Millis, parseRfc3339Millis, validContactId, validInviteId, validParticipantId, validToken } from "./ids.ts"
import { fail } from "./reject.ts"
import { conversationChanged, upsertParticipant, type Commit, type Draft, type OpRequest } from "./request.ts"
import { INVITE_TTL_MS, MAX_PARTICIPANTS, MAX_PENDING_INVITES, type ConversationHead, type DeliveryState, type Invite, type Participant } from "./types.ts"
import { currentParticipant } from "./validate.ts"

/**
 * Invite ops (home-messaging.md sections 4.1 and 5). Secrets never reach the
 * reducer: the host passes `token_hash`, which `invite.accept` must match
 * (the Domain derives it from a proof, so no event carries anything that can
 * accept; domain.ts). Every invite op by a participant first closes expired
 * open invites (a delivery report changes only its own invite).
 */

/** Forward-only order of delivery states; a report must move strictly up. */
export const DELIVERY_RANK: Readonly<Record<DeliveryState, number>> = {
  queued: 0,
  sent: 1,
  delivered: 2,
  bounced: 3,
  failed: 3,
  suppressed: 3,
  refused_env: 3,
  complained: 4
}

/** sha256 in base64url without padding (`hashInviteSecret`). */
const TOKEN_HASH = /^[A-Za-z0-9_-]{43}$/

const millis = (time: string): number => parseRfc3339Millis(time) ?? 0
export const isExpired = (invite: Invite, now: string): boolean => millis(now) >= millis(invite.expires_at)

const replaceInvite = (invites: ReadonlyArray<Invite>, invite: Invite): ReadonlyArray<Invite> =>
  invites.map((candidate) => (candidate.id === invite.id ? invite : candidate))

/** A contact with no open invite left departs (and outside a dm is dropped). */
const releaseContact = (head: ConversationHead, next: Draft, contact: string, now: string): void => {
  const open = (next.invites ?? []).some((invite) => invite.contact === contact && isOpen(invite))
  const record = next.participants.find((participant) => participant.id === contact)
  if (!open && record && record.left_at === undefined) next.participants = depart(head, next.participants, contact, now)
}

/** Open invites past their expiry become `expired` in this commit; their contacts are released. */
const closeExpired = (head: ConversationHead, next: Draft, now: string): void => {
  const expired = (next.invites ?? []).filter((invite) => isOpen(invite) && isExpired(invite, now))
  if (expired.length === 0) return
  next.invites = (next.invites ?? []).map((invite) => (expired.includes(invite) ? { ...invite, status: "expired" as const } : invite))
  for (const invite of expired) releaseContact(head, next, invite.contact, now)
}

/** `invite.create`: adds (or re-adds) the contact participant and a pending invite. */
export const createInvite = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, op: OpOf<"invite.create">): Commit => {
  if (head.kind === "chief") fail("kind_forbids")
  if (actor.kind !== "human") fail("forbidden")
  const shortToken = (value: unknown) => typeof value === "string" && validToken(value) && value.length <= 16
  const valid =
    typeof op.invite_id === "string" &&
    validInviteId(op.invite_id) &&
    typeof op.contact === "string" &&
    validContactId(op.contact) &&
    (op.channel === "email" || op.channel === "sms") &&
    validName(op.display_name) &&
    typeof op.token_hash === "string" &&
    TOKEN_HASH.test(op.token_hash) &&
    shortToken(op.locale) &&
    shortToken(op.copy_variant)
  if (!valid) fail("invalid_invite")
  const now = request.now
  closeExpired(head, next, now)
  const invites = next.invites ?? []
  if (invites.some((invite) => invite.id === op.invite_id || invite.token_hash === op.token_hash)) fail("duplicate_invite")
  if (invites.some((invite) => invite.contact === op.contact && isOpen(invite))) fail("duplicate_invite")
  if (invites.filter(isOpen).length >= MAX_PENDING_INVITES) fail("invite_limit")
  const existing = next.participants.find((participant) => participant.id === op.contact)
  // A dm invites only its own contact peer (dm.open created it).
  if (head.kind === "dm" && !existing) fail("kind_forbids")
  if (existing && existing.kind !== "contact") fail("invalid_invite")
  if (!existing || existing.left_at !== undefined) {
    if (next.participants.filter((participant) => participant.left_at === undefined).length >= MAX_PARTICIPANTS) fail("invalid_participant")
    next.participants = upsertParticipant(next.participants, {
      id: op.contact,
      kind: "contact",
      display_name: op.display_name,
      role: "member",
      joined_seq: head.last_seq,
      added_by: actor.id
    })
  }
  const invite: Invite = {
    id: op.invite_id,
    contact: op.contact,
    channel: op.channel,
    display_name: op.display_name,
    invited_by: actor.id,
    created_at: now,
    expires_at: formatRfc3339Millis(millis(now) + INVITE_TTL_MS),
    token_hash: op.token_hash,
    status: "pending",
    delivery: { state: "queued", at: now },
    copy_variant: op.copy_variant,
    locale: op.locale
  }
  next.invites = [...invites, invite]
  next.updated_at = now
  return conversationChanged(next, request)
}

/** `invite.revoke`: inviter or conversation owner; open invites only. The contact leaves with its last open invite. */
export const revokeInvite = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, op: OpOf<"invite.revoke">): Commit => {
  const target = (head.invites ?? []).find((candidate) => candidate.id === op.invite_id)
  if (!target) return fail("unknown_invite")
  if (target.invited_by !== actor.id && actor.role !== "owner") fail("forbidden")
  closeExpired(head, next, request.now)
  const invite = (next.invites ?? []).find((candidate) => candidate.id === op.invite_id)!
  if (!isOpen(invite)) fail("invite_not_pending")
  next.invites = replaceInvite(next.invites ?? [], { ...invite, status: "revoked" })
  releaseContact(head, next, invite.contact, request.now)
  next.updated_at = request.now
  return conversationChanged(next, request)
}

/**
 * Binds `user` to an invite: the user replaces the contact participant in
 * place (keeping its `joined_seq`, so history since the invite is visible) and
 * the invite becomes `accepted`. A user who is already a participant (invited
 * under two addresses) only consumes the invite; the contact leaves.
 */
const bindUser = (head: ConversationHead, next: Draft, invite: Invite, user: string, name: string, now: string): void => {
  const contact = currentParticipant(next as ConversationHead, invite.contact)
  let participants = next.participants
  if (!currentParticipant(next as ConversationHead, user)) {
    // A departed record of the same user is replaced, so ids stay unique.
    participants = participants.filter((participant) => participant.id !== user)
    const joined: Participant = {
      id: user,
      kind: "human",
      display_name: name,
      role: "member",
      joined_seq: contact?.joined_seq ?? head.last_seq,
      added_by: invite.invited_by
    }
    if (contact) {
      participants = participants.map((participant) => (participant.id === contact.id ? joined : participant))
    } else {
      if (participants.filter((participant) => participant.left_at === undefined).length >= MAX_PARTICIPANTS) fail("invalid_participant")
      participants = [...participants, joined]
    }
  } else if (contact) {
    participants = depart(head, participants, contact.id, now)
  }
  next.participants = participants
  const { requested_by: _by, requested_name: _name, requested_at: _at, ...rest } = invite
  next.invites = replaceInvite(next.invites ?? [], { ...rest, status: "accepted", accepted_by: user, accepted_at: now })
  next.updated_at = now
}

/**
 * `invite.accept`: any signed-in user holding the link (the host passes the
 * token hash). Single use: pending and not expired. A dm invite binds any
 * holder once. A group invite binds at once only for an email invite whose
 * contact is one of the actor's verified addresses (`actor_contacts`);
 * otherwise, and always for SMS (no principal carries a verified phone), it
 * waits for `invite.approve_join` (D-H4).
 */
export const acceptInvite = (head: ConversationHead, next: Draft, request: OpRequest, op: OpOf<"invite.accept">): Commit => {
  if (head.state === "archived") fail("archived")
  const user = request.actor
  if (!user.startsWith("user_") || !validParticipantId(user) || !validName(op.display_name)) fail("invalid_participant")
  const invites = head.invites ?? []
  const invite = typeof op.token_hash === "string" ? invites.find((candidate) => candidate.token_hash === op.token_hash) : undefined
  if (!invite) return fail("unknown_invite")
  if (invite.status !== "pending") fail("invite_not_pending")
  if (isExpired(invite, request.now)) fail("invite_expired")
  if (invite.invited_by === user) fail("invite_self")
  closeExpired(head, next, request.now)
  const verified = invite.channel === "email" && (request.actor_contacts?.includes(invite.contact) ?? false)
  if (head.kind === "group" && !verified) {
    next.invites = replaceInvite(next.invites ?? [], { ...invite, status: "pending_approval", requested_by: user, requested_name: op.display_name, requested_at: request.now })
    return conversationChanged(next, request)
  }
  bindUser(head, next, invite, user, op.display_name, request.now)
  return conversationChanged(next, request)
}

/**
 * `invite.approve_join`: the inviter or the conversation owner lets the
 * requesting user in, or declines with `approve: false` (the invite closes as
 * `revoked`; the link was used by someone else). Not after the expiry.
 */
export const approveJoin = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, op: OpOf<"invite.approve_join">): Commit => {
  const invite = (head.invites ?? []).find((candidate) => candidate.id === op.invite_id)
  if (!invite) return fail("unknown_invite")
  if (op.approve !== undefined && typeof op.approve !== "boolean") fail("invalid_invite")
  if (invite.status !== "pending_approval" || invite.requested_by === undefined) return fail("invite_not_pending")
  if (invite.invited_by !== actor.id && actor.role !== "owner") fail("forbidden")
  if (isExpired(invite, request.now)) fail("invite_expired")
  closeExpired(head, next, request.now)
  if (op.approve === false) {
    const { requested_by: _by, requested_name: _name, requested_at: _at, ...rest } = invite
    next.invites = replaceInvite(next.invites ?? [], { ...rest, status: "revoked" })
    releaseContact(head, next, invite.contact, request.now)
    next.updated_at = request.now
    return conversationChanged(next, request)
  }
  bindUser(head, next, invite, invite.requested_by, invite.requested_name ?? invite.display_name, request.now)
  return conversationChanged(next, request)
}

/**
 * `invite.delivery.report` (system, from ContactDO): the delivery state only
 * moves forward. `provider_id` is optional (absent, never null).
 */
export const reportDelivery = (head: ConversationHead, next: Draft, request: OpRequest, op: OpOf<"invite.delivery.report">): Commit => {
  const state = op.delivery?.state
  const providerId = op.delivery?.provider_id
  if (state === undefined || !Object.hasOwn(DELIVERY_RANK, state) || (providerId !== undefined && !(typeof providerId === "string" && validToken(providerId)))) {
    return fail("invalid_invite")
  }
  const known = (head.invites ?? []).find((candidate) => candidate.id === op.invite_id)
  if (!known) return fail("unknown_invite")
  if (DELIVERY_RANK[state] <= DELIVERY_RANK[known.delivery.state]) fail("delivery_regression")
  // Only the delivery moves here (the change carries one invite); participant ops close expired invites.
  const invite = known
  const keptProvider = providerId ?? invite.delivery.provider_id
  const updated: Invite = { ...invite, delivery: { state, ...(keptProvider === undefined ? {} : { provider_id: keptProvider }), at: request.now } }
  next.invites = replaceInvite(next.invites ?? [], updated)
  const { token_hash: _hidden, ...visible } = updated
  return { head: next, change: { kind: "invite", conversation: head.id, invite: visible } }
}
