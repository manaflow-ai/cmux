import { createHash } from "node:crypto"
import { canonicalJson, type Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { roleHas } from "./domains/team-roles.ts"
import { principalForOwner } from "./team-select.ts"
import { withGrantClasses } from "./auth.ts"
import { mcpScopesForGrant } from "./mcp-grant.ts"

export const agentGatewayOn = (env: Env) => env.PLATFORM_AGENT_GATEWAY === "on" && (env.ENVIRONMENT === "development" || env.ENVIRONMENT === "test")
// The stored approval retains the source install/grant and original chief identity (if any).
// MCP's agent field is an invocation identity, never a chief id to pass to UserDO.installGrant.
type GatewayPrincipal = Principal & { readonly mcp_session: string; readonly mcp_caller_agent?: string }
const identity = (p: Principal, session: string, callerAgent?: string) => `platform-mcp:${createHash("sha256").update(canonicalJson({ user: p.user, team: p.team, install: p.install, grant: p.grant, agent: callerAgent ?? null, session })).digest("hex")}`

/** Only the named binding builds this principal. Source install provenance survives conversion. */
export const agentGatewayPrincipal = (caller: Principal, session: string): GatewayPrincipal => ({
  ...caller, kind: "agent", identity: identity(caller, session, caller.agent), agent: session,
  mcp_session: session, ...(caller.agent ? { mcp_caller_agent: caller.agent } : {}), grant_classes: []
})

export const isAgentGatewayPrincipal = (p: Principal): p is GatewayPrincipal => {
  const saved = p as GatewayPrincipal
  return p.kind === "agent" && !!p.user && !!p.team && !!p.install && !!p.grant && !!saved.mcp_session &&
    p.agent === saved.mcp_session && p.identity === identity(p, saved.mcp_session, saved.mcp_caller_agent)
}

/** Re-resolve at admission, approval execution, and immediately before the provider POST. */
export const resolveConnectionPrincipal = async (env: Env, p: Principal): Promise<Principal | { refused: string } | undefined> => {
  if (!isAgentGatewayPrincipal(p)) return principalForOwner(env, "cloud:ConnectionDO", p)
  if (!agentGatewayOn(env)) return undefined
  const source = { ...p, kind: "install" as const, identity: p.install!, agent: p.mcp_caller_agent }
  const live = await withGrantClasses(env, source)
  if (!live || !mcpScopesForGrant(live.install_kind, live.grant_classes).includes("mcp:write")) return undefined
  const team = env.TEAM_DO.get(env.TEAM_DO.idFromName(p.team!)) as unknown as { memberRole(entity: string, user: string): Promise<string | null> }
  const role = await team.memberRole(p.team!, p.user!)
  if (!roleHas(role ?? undefined, "team.resources")) return undefined
  return agentGatewayPrincipal(live, p.mcp_session)
}
