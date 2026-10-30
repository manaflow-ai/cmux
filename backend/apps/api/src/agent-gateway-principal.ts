import { createHash } from "node:crypto"
import { canonicalJson, type Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { roleHas } from "./domains/team-roles.ts"
import { withGrantClasses } from "./auth.ts"
import { principalForOwner } from "./team-select.ts"

export const agentGatewayOn = (env: Env) => env.PLATFORM_AGENT_GATEWAY === "on" && (env.ENVIRONMENT === "development" || env.ENVIRONMENT === "test")
const identity = (user: string, team: string, session: string) => `platform-mcp:${createHash("sha256").update(canonicalJson({ user, team, session })).digest("hex")}`

/** Only the named binding builds this principal. No HTTP authentication path accepts these fields. */
export const agentGatewayPrincipal = (user: string, team: string, session: string, source?: Principal): Principal => ({
  kind: "agent", identity: identity(user, team, session), user, team, agent: session, grant_classes: [],
  ...(source?.kind === "install" && source.install && source.grant ? { source_install: source.install, source_grant: source.grant, ...(source.agent ? { source_agent: source.agent } : {}) } : {})
})

export const isAgentGatewayPrincipal = (p: Principal) => p.kind === "agent" && !!p.user && !!p.team && !!p.agent && p.identity === identity(p.user, p.team, p.agent)

/** Re-resolve at admission, approval execution, and immediately before the provider POST. */
export const resolveConnectionPrincipal = async (env: Env, p: Principal): Promise<Principal | { refused: string } | undefined> => {
  if (!isAgentGatewayPrincipal(p)) return principalForOwner(env, "cloud:ConnectionDO", p)
  if (!agentGatewayOn(env)) return undefined
  const team = env.TEAM_DO.get(env.TEAM_DO.idFromName(p.team!)) as unknown as { memberRole(entity: string, user: string): Promise<string | null> }
  const role = await team.memberRole(p.team!, p.user!)
  if (!roleHas(role ?? undefined, "team.resources")) return undefined
  // Keep the gateway identity stable while rechecking the original install grant. A synthetic
  // agent must never turn a revoked bearer into an authenticated call.
  if (p.source_install && p.source_grant) {
    const source: Principal = { kind: "install", identity: p.source_install, user: p.user, team: p.team, install: p.source_install, grant: p.source_grant, ...(p.source_agent ? { agent: p.source_agent } : {}) }
    const live = await withGrantClasses(env, source)
    if (!live) return undefined
    return { ...p, grant_classes: live.grant_classes }
  }
  return p
}
