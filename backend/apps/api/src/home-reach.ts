import { conversation as homeConversation } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import { personalTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"

/**
 * Worker side of the human reach rule (home-messaging.md sections 4.1 and 16; the rule itself is
 * home-core `reachDecision`). Before an op that would add humans (conversation.create, dm.open
 * by user id, participants.add) the Worker asks each fact's owner and passes the answers to the
 * ConversationDO in `principal.home_reach`, so the reducer stays pure:
 *
 * - shared team: TeamDO `homeCoMembers` for the caller's teams (the principal's team and SSO
 *   team) and the target's personal team. A user's other teams need a membership index in
 *   UserDO (section 16.7, not built), so only those teams are checked.
 * - connected: until relationships exist (16.7), a DM between the two where both are current
 *   participants and both gave consent (16.8: both sent a message, or one accepted the other's
 *   invite), found through the caller's inbox `peer` index and asked of that DM's owner.
 * - allow_dm_from: the target's UserDO, asked only when one of the links above exists, so an
 *   unknown id never reaches another user's object.
 * - blocked: not resolved; the pair state (16.6) does not exist yet.
 *
 * A target with no link gets no entry, which the reducer refuses with the same code as a
 * refusal by setting, so the caller cannot tell whether an account exists.
 */

/** Group size cap (section 4.1); more targets than this are never resolved. */
const MAX_TARGETS = 64
const MAX_ID = 64

interface TeamReachStub {
  homeCoMembers(entity: string, adder: string, targets: ReadonlyArray<string>): Promise<Array<{ user: string; display_name: string }>>
}
interface UserReachStub {
  readInbox(entity: string, principal: Principal, op: string, params: Record<string, unknown>): Promise<{ ok: boolean; value?: { conversation?: string | null } }>
  homeAllowDmFrom(entity: string): Promise<homeConversation.AllowDmFrom>
}
interface ConversationReachStub {
  homeDmLink(entity: string, adder: string, target: string): Promise<{ peer: string | null; consented: boolean } | null>
  mayInvite(entity: string, principal: Principal): Promise<boolean>
}

const teamStub = (env: Env, team: string) => env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as TeamReachStub
const userStub = (env: Env, user: string) => env.USER_DO.get(env.USER_DO.idFromName(user)) as unknown as UserReachStub
const conversationStub = (env: Env, id: string) => env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(id)) as unknown as ConversationReachStub

export interface ReachResolution {
  /** The caller with `home_reach` set (unchanged for callers that are not a signed-in human). */
  readonly principal: Principal
  /** Target user id -> the caller's existing DM with them (both are current participants). */
  readonly dms: ReadonlyMap<string, string>
}

/** The human targets of an op: distinct `user_` ids other than the caller. */
export const humanTargets = (caller: string, ids: ReadonlyArray<unknown>): Array<string> =>
  [...new Set(ids.filter((id): id is string => typeof id === "string" && id.startsWith("user_") && id.length <= MAX_ID && id !== caller))].slice(0, MAX_TARGETS)

/**
 * The caller's DM with `target`: `peer` is set while both are current participants (only then is
 * the DM reused by dm.open), and `consented` when the pair gave consent (16.8), which alone makes
 * them connected. A DM opened through team reach that the target never answered is no contact.
 */
const existingDm = async (env: Env, principal: Principal, adder: string, target: string) => {
  const found = await userStub(env, adder).readInbox(adder, principal, "inbox.dm_peer", { peer: target })
  const id = found.ok ? found.value?.conversation : null
  if (!id) return null
  const link = await conversationStub(env, id).homeDmLink(id, adder, target)
  return link ? { id, ...link } : null
}

/** Whether the caller is a current participant of `conversation` (participants.add resolves reach only then). */
export const isParticipant = (env: Env, conversation: string, principal: Principal): Promise<boolean> => conversationStub(env, conversation).mayInvite(conversation, principal)

/** Resolves the reach facts for `targets` (already filtered by `humanTargets`). */
export const resolveHumanReach = async (env: Env, principal: Principal, targets: ReadonlyArray<string>): Promise<ReachResolution> => {
  const adder = homeConversation.actorOf(principal)
  // Chiefs and other non-human callers keep the old rule (no facts: only known participants).
  if (!adder?.startsWith("user_") || principal.agent || principal.kind === "system") return { principal, dms: new Map() }
  if (targets.length === 0) return { principal: { ...principal, home_reach: [] }, dms: new Map() }
  const ownTeams = [...new Set([principal.team, principal.sso_team].filter((t): t is string => typeof t === "string"))]
  const [ownShared, theirShared, dms] = await Promise.all([
    Promise.all(ownTeams.map((team) => teamStub(env, team).homeCoMembers(team, adder, targets))),
    Promise.all(targets.map((target) => teamStub(env, personalTeamIdFor(target)).homeCoMembers(personalTeamIdFor(target), adder, [target]))),
    Promise.all(targets.map((target) => existingDm(env, principal, adder, target)))
  ])
  const teamNames = new Map<string, string>()
  for (const hit of [...ownShared.flat(), ...theirShared.flat()]) if (!teamNames.has(hit.user)) teamNames.set(hit.user, hit.display_name)
  const linked = targets.flatMap((target, i) => {
    const dm = dms[i]
    const connected = dm?.peer != null && dm.consented
    const name = teamNames.get(target) ?? (connected ? dm.peer! : undefined)
    return name === undefined ? [] : [{ target, name, shared_team: teamNames.has(target), connected }]
  })
  const settings = await Promise.all(linked.map((l) => userStub(env, l.target).homeAllowDmFrom(l.target)))
  const home_reach = linked.map((l, i) => ({ user: l.target, display_name: l.name, shared_team: l.shared_team, connected: l.connected, allow_dm_from: settings[i]! }))
  const existing = new Map<string, string>()
  targets.forEach((target, i) => {
    const dm = dms[i]
    if (dm?.peer != null) existing.set(target, dm.id)
  })
  return { principal: { ...principal, home_reach }, dms: existing }
}
