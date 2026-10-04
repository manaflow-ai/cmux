import { safeDisplayName } from "./validate.ts"

/**
 * The human reach rule (home-messaging.md sections 4.1, 4.2 and 16): who may DM a human, put
 * them into a new group, or add them to a conversation.
 *
 * A human may be added only by someone who shares a team with them (16.2, 16.7) or is already
 * connected to them (4.1 "already share a conversation", 16.7 "connected"); the target's
 * `allow_dm_from` setting (4.2) narrows that:
 * - `anyone`: a shared team or a connection;
 * - `teams`: a shared team only;
 * - `contacts`: a connection only.
 * A block on the pair (16.6) refuses everything. Strangers get the invite flow instead.
 *
 * The facts are resolved by the Worker from their owners (TeamDO membership, the caller's
 * UserDO inbox and the pair's DM, the target's UserDO settings) and passed to the owner in the
 * principal, so the reducer stays pure. Every refusal, and an account the Worker found nothing
 * for, is `not_reachable`: the caller cannot tell an unknown account from a refusal (section 9).
 */
export type AllowDmFrom = "anyone" | "teams" | "contacts"

export const ALLOW_DM_FROM: ReadonlyArray<AllowDmFrom> = ["anyone", "teams", "contacts"]

export interface HumanReach {
  /** The target's `user_` id. */
  readonly user: string
  /** Trusted name from the owner that proved the link (team directory or the pair's DM). */
  readonly display_name: string
  /** The caller and the target are members of one team, and the caller's role may add people. */
  readonly shared_team: boolean
  /** The pair is connected; until relationships (16.7) are built: a DM where both are current participants. */
  readonly connected: boolean
  /** The target's setting (UserDO `home.settings.set`). */
  readonly allow_dm_from: AllowDmFrom
  /** Either side blocked the other (16.6); not resolved until the pair state exists. */
  readonly blocked?: boolean
}

/** The one reject code for every refused or unknown human. */
export const NOT_REACHABLE = "not_reachable"

/** Fallback when a trusted name is empty after cleaning (same as policy.ts FALLBACK_NAME). */
const FALLBACK = "Member"

export type ReachDecision = { readonly ok: true; readonly display_name: string } | { readonly ok: false; readonly code: string }

/** The rule above, for one target. `undefined` = the Worker found no link (or no account). */
export const reachDecision = (reach: HumanReach | undefined): ReachDecision => {
  if (!reach || reach.blocked === true) return { ok: false, code: NOT_REACHABLE }
  const allowed =
    reach.allow_dm_from === "anyone" ? reach.shared_team || reach.connected : reach.allow_dm_from === "teams" ? reach.shared_team : reach.allow_dm_from === "contacts" ? reach.connected : false
  if (!allowed) return { ok: false, code: NOT_REACHABLE }
  return { ok: true, display_name: safeDisplayName(reach.display_name, FALLBACK) }
}
