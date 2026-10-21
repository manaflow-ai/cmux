import type { OpOf } from "./cloud.ts"
import { formatRfc3339Millis, parseRfc3339Millis } from "./ids.ts"
import { fail } from "./reject.ts"
import { conversationChanged, type Commit, type Draft, type OpRequest } from "./request.ts"
import { checkGrant, grantableRole, rankOf } from "./roles.ts"
import type { ClosedGrant, ConversationHead, Grant, Participant, ParticipantRole } from "./types.ts"

/**
 * Link grants (plans/cmux-next/home-dm-group-chats/DESIGN.md section 2.1): a capability to join a
 * group with one role, held as a secret in a link (`<origin>/i/g<26>#<secret>`, the invite link
 * format, so the same accept page and `invite.accept` redeem it).
 *
 * - The Worker derives `grant_id` and the secret; the conversation stores only
 *   `token_hash = sha256(sha256(secret))` in the private `granthash` table. A redeem passes
 *   `proof = sha256(secret)` (domain.ts), so no event carries anything that can join.
 * - Attenuation: the link's role is at most its maker's (admin only from the owner), checked when
 *   it is made and again when it is used.
 * - Revocation: the maker, or a manager above the maker, revokes it; removing or demoting the
 *   maker closes every link it can no longer grant (`closeLostGrants`). It also closes after
 *   `max_uses` joins, and refuses after `expires_at`.
 */
export const TABLE_GRANT = "grant"
export const TABLE_GRANTHASH = "granthash"
/** Open links one group holds at once. */
export const MAX_OPEN_GRANTS = 50
export const DEFAULT_GRANT_HOURS = 7 * 24
export const MAX_GRANT_HOURS = 30 * 24
export const DEFAULT_GRANT_USES = 20
export const MAX_GRANT_USES = 1000

const GRANT_ID = /^grt_[0-9A-Z]{26}$/
const TOKEN_HASH = /^[A-Za-z0-9_-]{43}$/

const millis = (time: string): number => parseRfc3339Millis(time) ?? 0
export const grantExpired = (grant: Grant, now: string): boolean => millis(now) >= millis(grant.expires_at)

const boundedInt = (value: unknown, fallback: number, max: number): number => {
  if (value === undefined) return fallback
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > max) return fail("invalid_invite")
  return value
}

/** Whether `maker` (its current record, or none) may still grant `role`. */
export const mayStillGrant = (maker: Participant | undefined, role: ParticipantRole): boolean => {
  if (!maker || maker.left_at !== undefined || maker.kind !== "human") return false
  try {
    if (rankOf(maker) === 0) return false
    checkGrant(maker, role)
    return true
  } catch {
    return false
  }
}

/** `grant.create`: a current, writing member makes a link at or below its own role. */
export const createGrant = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, op: OpOf<"grant.create">): Commit => {
  if (head.kind !== "group") fail("kind_forbids")
  if (actor.kind !== "human") fail("forbidden")
  if (typeof op.grant_id !== "string" || !GRANT_ID.test(op.grant_id) || typeof op.token_hash !== "string" || !TOKEN_HASH.test(op.token_hash)) fail("invalid_invite")
  const role = op.role === undefined ? "member" : grantableRole(op.role)
  checkGrant(actor, role)
  const hours = boundedInt(op.expires_in_hours, DEFAULT_GRANT_HOURS, MAX_GRANT_HOURS)
  const uses = boundedInt(op.max_uses, DEFAULT_GRANT_USES, MAX_GRANT_USES)
  const open = (head.grants ?? []).filter((grant) => !grantExpired(grant, request.now))
  if (open.some((grant) => grant.id === op.grant_id)) fail("duplicate_invite")
  if (open.length >= MAX_OPEN_GRANTS) fail("invite_limit")
  const grant: Grant = {
    id: op.grant_id,
    role,
    issuer: actor.id,
    created_at: request.now,
    expires_at: formatRfc3339Millis(millis(request.now) + hours * 3600_000),
    max_uses: uses,
    uses: 0
  }
  next.grants = [...open, grant]
  return conversationChanged(next, request)
}

/** `grant.revoke`: the maker, or a manager strictly above the maker (the owner always). */
export const revokeGrant = (head: ConversationHead, next: Draft, request: OpRequest, actor: Participant, op: OpOf<"grant.revoke">): Commit => {
  const grant = (head.grants ?? []).find((candidate) => candidate.id === op.grant_id)
  if (!grant) return fail("unknown_invite")
  // The view head holds the maker's record (domain.ts names it).
  const maker = head.participants.find((participant) => participant.id === grant.issuer && participant.left_at === undefined)
  const own = grant.issuer === actor.id
  const above = rankOf(actor) >= 2 && (actor.role === "owner" || !maker || rankOf(actor) > rankOf(maker))
  if (!own && !above) fail("forbidden")
  next.grants = (head.grants ?? []).filter((candidate) => candidate.id !== grant.id)
  return conversationChanged(next, request)
}

/** A grant leaving the head, as its row keeps it. */
export const closedGrant = (grant: Grant, closed: ClosedGrant["closed"], now: string, by?: string): ClosedGrant => ({
  ...grant,
  closed_at: now,
  closed,
  ...(by === undefined ? {} : { closed_by: by })
})

/**
 * Closes the open grants whose maker can no longer grant their role (removed, left, demoted),
 * for the makers this commit could have changed. `recordOf` reads the committed records.
 */
export const closeLostGrants = (
  grants: ReadonlyArray<Grant>,
  makers: ReadonlySet<string>,
  recordOf: (id: string) => Participant | undefined
): { open: Array<Grant>; lost: Array<Grant> } => {
  const open: Array<Grant> = []
  const lost: Array<Grant> = []
  for (const grant of grants) (makers.has(grant.issuer) && !mayStillGrant(recordOf(grant.issuer), grant.role) ? lost : open).push(grant)
  return { open, lost }
}
