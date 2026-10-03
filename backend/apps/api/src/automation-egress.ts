import { WorkerEntrypoint } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { hostAllowed } from "./egress-hosts.ts"
import type { EgressAdmission } from "./usage-meter-do.ts"

export { hostAllowed } from "./egress-hosts.ts"

/** What the loader attaches to a tenant Dynamic Worker's `globalOutbound` (code-run.ts). */
export interface AutomationEgressProps {
  readonly team: string
  /** The code body's `egress` list (protocol EgressHost): exact hosts or `*.domain`. */
  readonly hosts: ReadonlyArray<string>
}

/** Test seam (ENVIRONMENT=test only): answers allowed requests instead of the network. */
export const egressTest: { upstream?: (url: string, init: RequestInit) => Promise<Response> } = {}

const refuse = (status: number, code: string, message: string) =>
  new Response(JSON.stringify({ error: { code, message } }), { status, headers: { "content-type": "application/json", "x-cmux-egress": "refused" } })

/** Request headers the gateway never forwards (hop-by-hop, or ones that could steer the edge or a proxy). */
const DROPPED = new Set(["host", "connection", "keep-alive", "proxy-authorization", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade", "x-real-ip", "forwarded", "true-client-ip", "cdn-loop"])
const dropped = (k: string) => DROPPED.has(k) || k.startsWith("cf-") || k.startsWith("x-forwarded-")

/**
 * The egress gateway (automations plan slice 4, automations-billing.md 5.5): every
 * `fetch` of tenant code goes here (`globalOutbound`). It allows only HTTPS on port 443
 * to hosts in the code body's allowlist, at most EGRESS_PER_MINUTE requests per team per
 * minute, and nothing once the team is at its hard cap. Each allowed request is one
 * `egress.requests` record. The forwarded request is rebuilt from the URL, method,
 * headers and body only (no `cf` options), with redirects not followed, so a redirect
 * comes back to tenant code and its next request passes this gate again. Tenant code holds
 * no credential, so nothing secret can leave through it.
 */
export class AutomationEgress extends WorkerEntrypoint<Env, AutomationEgressProps> {
  /** Raw TCP (`cloudflare:sockets` connect) is never allowed: only HTTPS through `fetch`. */
  override connect(socket: Socket): void {
    void socket.close()
    throw new Error("egress.denied: automation code may not open raw sockets")
  }

  override async fetch(request: Request): Promise<Response> {
    const p = this.ctx.props
    let url: URL
    try {
      url = new URL(request.url)
    } catch {
      return refuse(400, "egress.invalid", "the request URL is not valid")
    }
    if (url.protocol !== "https:" || (url.port !== "" && url.port !== "443") || url.username !== "" || url.password !== "") {
      return refuse(403, "egress.denied", "automation code may only make HTTPS requests on port 443")
    }
    const host = url.hostname.toLowerCase()
    if (!hostAllowed(host, p.hosts)) return refuse(403, "egress.denied", `${host} is not in this automation's egress list`)
    const meter = this.env.USAGE_METER_DO.get(this.env.USAGE_METER_DO.idFromName(p.team))
    const admission = (await meter.egressAdmit(p.team)) as unknown as EgressAdmission
    if (!admission.allowed) return refuse(403, "budget.cap_reached", "the team's automation spending cap is reached")
    if (admission.limited) return refuse(429, "egress.rate_limited", "too many outbound requests from this team's automations; retry in a minute")
    const headers = new Headers()
    request.headers.forEach((v, k) => {
      if (!dropped(k.toLowerCase())) headers.set(k, v)
    })
    const hasBody = request.method !== "GET" && request.method !== "HEAD"
    const init: RequestInit = { method: request.method, headers, body: hasBody ? request.body : null, redirect: "manual" }
    const res = this.env.ENVIRONMENT === "test" && egressTest.upstream ? await egressTest.upstream(url.toString(), init) : await fetch(url.toString(), init)
    // Counted only once the upstream answered (never over-bill a request that failed).
    await meter.egressDone(p.team)
    return res
  }
}
