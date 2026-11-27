import { fail } from "./reject.ts"
import type { Participant, ParticipantRole } from "./types.ts"

/**
 * Roles in a cloud group (plans/cmux-next/home-dm-group-chats/DESIGN.md section 4), checked by
 * the conversation's owner on every op:
 *
 * - owner: one per conversation; everything, and only it makes admins or hands the group on.
 * - admin: renames, adds, removes, bans and unbans people below admin, sets member/read_only.
 * - member: talks, renames, adds members or read-only people, leaves.
 * - read_only: reads, moves its own read cursor, leaves. Never writes to the conversation.
 *
 * A role is granted only at or below the granter's own, and admin only by the owner
 * (attenuation). A record without a role (an agent, an older head) is a member.
 */
export const ROLES: ReadonlyArray<ParticipantRole> = ["owner", "admin", "member", "read_only"]

const RANK: Readonly<Record<ParticipantRole, number>> = { read_only: 0, member: 1, admin: 2, owner: 3 }

export const roleOf = (participant: Participant): ParticipantRole => participant.role ?? "member"
export const rankOf = (participant: Participant): number => RANK[roleOf(participant)]

/** At least an admin (the owner included). */
export const isManager = (participant: Participant): boolean => rankOf(participant) >= RANK.admin

/** Ops a read-only member may still run: reading state, its cursor, and leaving. */
const READ_ONLY_OPS = new Set(["read_cursor.set", "participants.remove"])

/** Refuses a write by a read-only member (`read_only`). Leaving is allowed: remove checks it is self. */
export const checkWriter = (actor: Participant, opKind: string, target?: string): void => {
  if (roleOf(actor) !== "read_only") return
  if (!READ_ONLY_OPS.has(opKind)) fail("read_only")
  if (opKind === "participants.remove" && target !== actor.id) fail("read_only")
}

/** A role name an op may set (`set_role`, an add's `role`): never owner, which is a transfer. */
export const grantableRole = (role: unknown): ParticipantRole => {
  if (role === "admin" || role === "member" || role === "read_only") return role
  return fail("invalid_role")
}

/** Whether `actor` may grant `role`: at most its own, and admin only from the owner. */
export const checkGrant = (actor: Participant, role: ParticipantRole): void => {
  if (RANK[role] > rankOf(actor)) fail("forbidden")
  if (role === "admin" && roleOf(actor) !== "owner") fail("forbidden")
}

/** Whether `actor` may change or remove `target`: a manager strictly above the target. */
export const checkOver = (actor: Participant, target: Participant): void => {
  if (!isManager(actor) || rankOf(actor) <= rankOf(target)) fail("forbidden")
}
