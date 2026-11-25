import { WorkerEntrypoint } from "cloudflare:workers"
import { createHash } from "node:crypto"
import { canonicalJson } from "@cmux/ownership"
import type { ExternalReply } from "./connection-do.ts"
import type { Env } from "./env.ts"
import { agentGatewayOn, agentGatewayPrincipal, resolveConnectionPrincipal } from "./agent-gateway-principal.ts"
import { authenticate, hasScope, withGrantClasses } from "./auth.ts"
import { mcpScopesForGrant } from "./mcp-grant.ts"
import { selectTeam, type TeamPrincipal } from "./team-select.ts"

export interface AgentIssueCommentRequest {
  /** The platform forwards the caller's bearer; this binding verifies it, never trusts body identity. */
  readonly authorization: string
  readonly team: string
  readonly connectionId: string
  readonly repo: string
  readonly issue: number
  readonly body: string
  readonly mcpSessionId: string
  readonly requestId: string
  readonly toolInvocationId: string
}

const ID = /^[A-Za-z0-9_.:-]{1,200}$/
const matches = (re: RegExp, value: unknown) => typeof value === "string" && re.test(value)
const refused = (code: string): ExternalReply => ({
  ok: false, op: "github.issue.comment", error: { code, message: "Agent gateway request refused", retryable: false },
  transaction: "", idempotency_key: "", replayed: false, stream: "", sequence: 0
})

/**
 * Account-local named service binding, never an HTTP route. The platform vouches for the verified
 * user/team and invocation identity. A bearer carried by an MCP call never makes it a human click.
 * Only github.issue.comment is accepted; credentials never leave ConnectionDO.
 */
export class AgentGateway extends WorkerEntrypoint<Env> {
  async dispatchIssueComment(input: AgentIssueCommentRequest): Promise<ExternalReply> {
    if (!agentGatewayOn(this.env)) return refused("platform.agent_gateway_off")
    if (!input || !matches(/^team_[0-9a-f]{20}$/, input.team)) return refused("validation.invalid")
    if (![input.mcpSessionId, input.requestId, input.toolInvocationId].every((v) => matches(ID, v))) return refused("validation.invalid")
    const bearer = /^Bearer\s+([^\s]+)$/i.exec(input.authorization)?.[1]
    const authenticated = await authenticate(this.env, bearer)
    if (!authenticated?.user || !authenticated.team) return refused("auth.forbidden")
    if (authenticated.kind !== "install" || !hasScope(authenticated, "mcp:write")) return refused("auth.insufficient_scope")
    const live = await withGrantClasses(this.env, authenticated)
    if (!live) return refused("auth.forbidden")
    if (!mcpScopesForGrant(live.install_kind, live.grant_classes).includes("mcp:write")) return refused("auth.insufficient_scope")
    const selected = await selectTeam(this.env, live as TeamPrincipal, input.team)
    if (!selected.ok || selected.principal.team !== input.team) return refused("auth.forbidden")
    const principal = agentGatewayPrincipal(selected.principal, input.mcpSessionId)
    try {
      const resolved = await resolveConnectionPrincipal(this.env, principal)
      if (!resolved || "refused" in resolved) return refused("auth.forbidden")
      const stub = this.env.CONNECTION_DO.get(this.env.CONNECTION_DO.idFromName(input.team))
      return await stub.external(input.team, principal, {
        op: "github.issue.comment",
        params: { connection: input.connectionId, repo: input.repo, issue: input.issue, body: input.body },
        idempotency_key: `mcp:${createHash("sha256").update(canonicalJson({ session: input.mcpSessionId, request: input.requestId, invocation: input.toolInvocationId })).digest("hex")}`
      })
    } catch {
      // A lost RPC acknowledgement may follow a committed effect. Only the same key is safe to retry.
      return refused("mutation.indeterminate")
    }
  }
}
