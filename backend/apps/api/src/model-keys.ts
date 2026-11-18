import { WorkerEntrypoint } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { resolveTeamSharedKey, type TeamAgent, type TeamSharedKey } from "./team-agent-keys.ts"

/**
 * The key store cmux-platform's model route reads (Cloud multiplayer C2/C4): its `MODEL_KEYS`
 * binding, `{ "binding": "MODEL_KEYS", "service": "cmux-api[-development|-staging]", "entrypoint":
 * "ModelKeys" }`, typed there as `ModelKeyStore` (src/server/cloud/ModelKeys.ts). An account-local
 * service binding, never an HTTP route: no client reaches it, and its answer goes only into the one
 * upstream model request.
 *
 * - `resolveTeamSharedKey(teamId, agent, ownerId)`: the team's shared key (team-agent-keys.ts) for a
 *   machine whose owner is still a member of the team, or null. The owner comes from the machine's
 *   token, which outlives a removal by up to its lifetime, so membership is checked here on every
 *   call; a call without an owner gets no key.
 * - `resolveOwnerProviderKey(ownerId, agent)`: null. cmux keeps no per-person provider API key for
 *   Cloud machines (a person's own subscription runs through their own gateway). It is answered,
 *   not left out: over a service binding a missing method throws, which the platform reads as an
 *   unreachable store and fails every call.
 *
 * Anything malformed answers null (no key), never an error: a bad id is no team's key.
 */
export class ModelKeys extends WorkerEntrypoint<Env> {
  async resolveTeamSharedKey(teamId: string, agent: string, ownerId?: string): Promise<TeamSharedKey | null> {
    return modelKeyForTeam(this.env, teamId, agent, ownerId)
  }

  async resolveOwnerProviderKey(_ownerId: string, _agent: string): Promise<TeamSharedKey | null> {
    return null
  }
}

const TEAM = /^team_[0-9a-f]{20}$/
const AGENTS: ReadonlyArray<string> = ["claude", "codex"]

/** [`ModelKeys.resolveTeamSharedKey`], for tests and the Worker's own model route. */
export const modelKeyForTeam = async (env: Pick<Env, "TEAM_DO">, teamId: unknown, agent: unknown, ownerId?: unknown): Promise<TeamSharedKey | null> => {
  if (typeof teamId !== "string" || !TEAM.test(teamId) || typeof agent !== "string" || !AGENTS.includes(agent)) return null
  if (typeof ownerId !== "string" || ownerId.length === 0) return null
  return resolveTeamSharedKey(env, teamId, agent as TeamAgent, { user: ownerId })
}
