import { conversation as homeConversation } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import { personalTeamIdFor } from "./domains/user.ts"
import { CHIEF_AGENT_CLASS } from "./domains/user-chief.ts"
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
 *   A shared group alone is no connection (16.3).
 * - allow_requests_from: the target's UserDO, asked only when one of the links above exists, so
 *   an unknown id never reaches another user's object.
 * - blocked: not resolved; the pair state (16.6) does not exist yet.
 *
 * A chief (an agent principal of class mux) acts under its owner's reach (CHIEF-DONE autonomy
 * rule): when the caller's class is mux and the owner's UserDO confirms the agent is one of the
 * owner's active chiefs, the facts are the owner's (the owner's teams, the owner's DMs, the
 * target's setting checked against the owner). Any other agent principal (an automation run
 * with a chief's id too) gets no facts but an empty list, so a cloud
 * owner refuses every human who is not a current participant, also a departed one.
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
  homeAllowRequestsFrom(entity: string): Promise<homeConversation.AllowRequestsFrom>
  homeChiefDms(entity: string, agent: string, agentClass: string, targets: ReadonlyArray<string>): Promise<Array<string | null> | null>
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
 * The adder's DM with `target` (id from the adder's inbox `peer` index): `peer` is set while both
 * are current participants (only then is the DM reused by dm.open), and `consented` when the pair
 * gave consent (16.8), which alone makes them connected. A DM opened through team reach that the
 * target never answered is no contact.
 */
const dmLink = async (env: Env, id: string | null | undefined, adder: string, target: string) => {
  if (!id) return null
  const link = await conversationStub(env, id).homeDmLink(id, adder, target)
  return link ? { id, ...link } : null
}

/**
 * The agent class of an agent principal: an automation run (automation-caps.ts: identity
 * `automation:<id>` and a `run`) is never a chief; every other agent principal claims the chief
 * class, which the owner's UserDO checks against its chief records (homeChiefDms).
 */
const agentClassOf = (principal: Principal): string => (principal.run !== undefined || principal.identity.startsWith("automation:") ? "automation" : CHIEF_AGENT_CLASS)

/** A signed-in human caller's DM ids, through its own inbox read. */
const ownDmIds = (env: Env, principal: Principal, adder: string, targets: ReadonlyArray<string>) =>
  Promise.all(
    targets.map(async (target) => {
      const found = await userStub(env, adder).readInbox(adder, principal, "inbox.dm_peer", { peer: target })
      return found.ok ? (found.value?.conversation ?? null) : null
    })
  )

/** Whether the caller is a current participant of `conversation` (participants.add resolves reach only then). */
export const isParticipant = (env: Env, conversation: string, principal: Principal): Promise<boolean> => conversationStub(env, conversation).mayInvite(conversation, principal)

/** Resolves the reach facts for `targets` (already filtered by `humanTargets`). */
export const resolveHumanReach = async (env: Env, principal: Principal, targets: ReadonlyArray<string>): Promise<ReachResolution> => {
  const actor = homeConversation.actorOf(principal)
  if (!actor || principal.kind === "system") return { principal, dms: new Map() }
  const none = { principal: { ...principal, home_reach: [] }, dms: new Map<string, string>() }
  // Who the facts are about: the caller, or a chief's owner once the owner confirms the chief.
  let adder: string
  let dmIds: ReadonlyArray<string | null>
  let ownTeams: ReadonlyArray<string>
  if (principal.agent) {
    const owner = principal.user ? (principal.user.startsWith("user_") ? principal.user : `user_${principal.user}`) : undefined
    if (!owner || !actor.startsWith("agent_")) return none
    const dms = targets.length === 0 ? [] : await userStub(env, owner).homeChiefDms(owner, actor, agentClassOf(principal), targets)
    if (dms === null) return none
    adder = owner
    dmIds = dms
    ownTeams = [personalTeamIdFor(owner), principal.team, principal.sso_team].filter((t): t is string => typeof t === "string")
  } else {
    if (!actor.startsWith("user_")) return { principal, dms: new Map() }
    adder = actor
    dmIds = targets.length === 0 ? [] : await ownDmIds(env, principal, adder, targets)
    ownTeams = [principal.team, principal.sso_team].filter((t): t is string => typeof t === "string")
  }
  if (targets.length === 0) return none
  const teams = [...new Set(ownTeams)]
  const [ownShared, theirShared, dms] = await Promise.all([
    Promise.all(teams.map((team) => teamStub(env, team).homeCoMembers(team, adder, targets))),
    Promise.all(targets.map((target) => teamStub(env, personalTeamIdFor(target)).homeCoMembers(personalTeamIdFor(target), adder, [target]))),
    Promise.all(targets.map((target, i) => dmLink(env, dmIds[i], adder, target)))
  ])
  const teamNames = new Map<string, string>()
  for (const hit of [...ownShared.flat(), ...theirShared.flat()]) if (!teamNames.has(hit.user)) teamNames.set(hit.user, hit.display_name)
  const linked = targets.flatMap((target, i) => {
    const dm = dms[i]
    const connected = dm?.peer != null && dm.consented
    const name = teamNames.get(target) ?? (connected ? dm.peer! : undefined)
    return name === undefined ? [] : [{ target, name, shared_team: teamNames.has(target), connected }]
  })
  const settings = await Promise.all(linked.map((l) => userStub(env, l.target).homeAllowRequestsFrom(l.target)))
  const home_reach = linked.map((l, i) => ({ user: l.target, display_name: l.name, shared_team: l.shared_team, connected: l.connected, allow_requests_from: settings[i]! }))
  const existing = new Map<string, string>()
  // dm.open reuses only the caller's own DM; a chief opens its own conversation.
  if (!principal.agent)
    targets.forEach((target, i) => {
      const dm = dms[i]
      if (dm?.peer != null) existing.set(target, dm.id)
    })
  return { principal: { ...principal, home_reach }, dms: existing }
}
