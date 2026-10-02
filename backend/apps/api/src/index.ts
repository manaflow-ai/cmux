import { authenticate, withGrantClasses } from "./auth.ts"
import type { Env } from "./env.ts"
import { apiHandler } from "./http.ts"
import { handleAutomationHook } from "./ingress/automation-hook.ts"
import { handleProviderHook } from "./ingress/provider-hook.ts"
import { handleSsoDiscover } from "./sso-discover.ts"
import { handlePairBegin, handlePairWait } from "./pair-routes.ts"

export { AccountIndexDO } from "./account-index-do.ts"
export { AddressDO } from "./address-do.ts"
export { ConversationDO } from "./conversation-do.ts"
export { MuxDO } from "./mux-do.ts"
export { DomainDO } from "./domain-do.ts"
export { PairingDO } from "./pairing-do.ts"
export { AutomationRunWorkflow } from "./automation-workflow.ts"
export { ConnectionDO } from "./connection-do.ts"
export { FeedDO } from "./feed-do.ts"
export { SchedulerDO } from "./scheduler-do.ts"
export { TeamDO } from "./team-do.ts"
export { UserDO } from "./user-do.ts"

/**
 * WebSocket gateway: `GET /v1/wire/{user|team|feed}` with subprotocols
 * `cmux.wire.v1, bearer.<token>` (browsers cannot set headers; the token stays
 * out of the URL and logs). The Worker authenticates and passes the principal
 * to the owner DO; frames never carry identity.
 */
const wire = async (request: Request, env: Env, scope: string): Promise<Response> => {
  const protocols = (request.headers.get("Sec-WebSocket-Protocol") ?? "").split(",").map((s) => s.trim())
  const token = protocols.find((p) => p.startsWith("bearer."))?.slice("bearer.".length)
  const authed = await authenticate(env, token)
  if (!authed?.user || !authed.team) return new Response("unauthenticated", { status: 401 })
  // TeamDO and FeedDO cannot see UserDO's revocations; resolve the grant first (UserDO checks its own installs).
  const principal = scope === "team" || scope === "feed" ? await withGrantClasses(env, authed) : authed
  if (!principal) return new Response("forbidden", { status: 403 })
  const [ns, entity] =
    scope === "user" ? [env.USER_DO, principal.user] : scope === "team" ? [env.TEAM_DO, principal.team] : scope === "feed" ? [env.FEED_DO, principal.user] : [undefined, undefined]
  if (!ns || !entity) return new Response("not found", { status: 404 })
  const headers = new Headers(request.headers)
  headers.set("x-cmux-entity", entity)
  headers.set("x-cmux-principal", JSON.stringify(principal))
  const stub = (ns as DurableObjectNamespace).get((ns as DurableObjectNamespace).idFromName(entity))
  return stub.fetch(new Request(request.url, { headers, method: "GET" }))
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    const m = url.pathname.match(/^\/v1\/wire\/(user|team|feed)$/)
    if (m && request.headers.get("Upgrade") === "websocket") return wire(request, env, m[1]!)
    // Webhook ingress: no bearer; each route verifies its own signature before any DO call.
    const hook = url.pathname.match(/^\/v1\/hooks\/automation\/([^/]+)\/([^/]+)$/)
    if (hook) return handleAutomationHook(request, env, hook[1]!, hook[2]!)
    if (url.pathname === "/v1/sso/discover") return handleSsoDiscover(request, env)
    // cmux server pairing: no account on the server side; each route verifies its own proof.
    if (url.pathname === "/v1/pair/begin") return handlePairBegin(request, env)
    if (url.pathname === "/v1/pair/wait") return handlePairWait(request, env)
    const providerHook = url.pathname.match(/^\/v1\/hooks\/(github|slack|linear)$/)
    if (providerHook) return handleProviderHook(request, env, providerHook[1] as "github" | "slack" | "linear")
    return apiHandler(request)
  }
} satisfies ExportedHandler<Env>
