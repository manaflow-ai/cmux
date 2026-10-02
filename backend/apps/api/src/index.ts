import { cleanupExpired, createFreestyleClient } from "@cmux/network-policy"
import { authenticate, withGrantClasses } from "./auth.ts"
import type { Env } from "./env.ts"
import { apiHandler } from "./http.ts"
import { handleAutomationHook } from "./ingress/automation-hook.ts"
import { handleProviderHook } from "./ingress/provider-hook.ts"
import { networkEnv } from "./team-do.ts"

export { AccountIndexDO } from "./account-index-do.ts"
export { AutomationRunWorkflow } from "./automation-workflow.ts"
export { ConnectionDO } from "./connection-do.ts"
export { SchedulerDO } from "./scheduler-do.ts"
export { TeamDO } from "./team-do.ts"
export { UserDO } from "./user-do.ts"

/**
 * WebSocket gateway: `GET /v1/wire/{user|team}` with subprotocols
 * `cmux.wire.v1, bearer.<token>` (browsers cannot set headers; the token stays
 * out of the URL and logs). The Worker authenticates and passes the principal
 * to the owner DO; frames never carry identity.
 */
const wire = async (request: Request, env: Env, scope: string): Promise<Response> => {
  const protocols = (request.headers.get("Sec-WebSocket-Protocol") ?? "").split(",").map((s) => s.trim())
  const token = protocols.find((p) => p.startsWith("bearer."))?.slice("bearer.".length)
  const authed = await authenticate(env, token)
  if (!authed?.user || !authed.team) return new Response("unauthenticated", { status: 401 })
  // TeamDO cannot see UserDO's revocations; resolve the grant first (UserDO checks its own installs).
  const principal = scope === "team" ? await withGrantClasses(env, authed) : authed
  if (!principal) return new Response("forbidden", { status: 403 })
  const [ns, entity] = scope === "user" ? [env.USER_DO, principal.user] : scope === "team" ? [env.TEAM_DO, principal.team] : [undefined, undefined]
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
    const m = url.pathname.match(/^\/v1\/wire\/(user|team)$/)
    if (m && request.headers.get("Upgrade") === "websocket") return wire(request, env, m[1]!)
    // Webhook ingress: no bearer; each route verifies its own signature before any DO call.
    const hook = url.pathname.match(/^\/v1\/hooks\/automation\/([^/]+)\/([^/]+)$/)
    if (hook) return handleAutomationHook(request, env, hook[1]!, hook[2]!)
    const providerHook = url.pathname.match(/^\/v1\/hooks\/(github|slack|linear)$/)
    if (providerHook) return handleProviderHook(request, env, providerHook[1] as "github" | "slack" | "linear")
    return apiHandler(request)
  },

  /**
   * Hourly (development and staging only): delete EXPIRED `cmuxnp-dev-` /
   * `cmuxnp-staging-` network resources in the shared Freestyle account.
   * Never runs in production and never touches anything without that prefix
   * and an expired stamp (network-policy cleanup.ts).
   */
  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    const ns = networkEnv(env.ENVIRONMENT)
    if (!ns || !env.FREESTYLE_API_KEY || (env.ENVIRONMENT !== "development" && env.ENVIRONMENT !== "staging")) return
    const api = createFreestyleClient({ apiKey: env.FREESTYLE_API_KEY, ...(env.FREESTYLE_API_URL ? { baseUrl: env.FREESTYLE_API_URL } : {}) })
    ctx.waitUntil(
      cleanupExpired(api, ns).then(
        (out) => console.log(JSON.stringify({ msg: "network cleanup", env: ns, deleted: out.filter((o) => o.ok).length, failed: out.filter((o) => !o.ok).map((o) => `${o.action.op}: ${o.error?.code}`) })),
        (e: unknown) => console.error(JSON.stringify({ msg: "network cleanup failed", env: ns, error: String(e) }))
      )
    )
  }
} satisfies ExportedHandler<Env>
