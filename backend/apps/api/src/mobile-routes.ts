import type { Principal } from "@cmux/ownership"
import { authenticate, withGrantClasses } from "./auth.ts"
import type { Env } from "./env.ts"
import { mobileConfig } from "./mobile-config.ts"
import { signInRules, ssoGate, ssoRefusal, versionRefusal, withSsoSession } from "./policy-gate.ts"
import { mintTurnCredentials } from "./realtime-turn.ts"
import { MOBILE_RATE_LIMITED, MOBILE_RATE_RETRY_SECONDS, mobileRateKey, takeMobileRate } from "./mobile-rate.ts"

/**
 * Worker routes of the mobile control plane (b1-control-do.md sections 2, 6 and 7): the HostDO
 * control socket, TURN credential minting and the remote config. Each authenticates the bearer
 * the same way as `/v1/wire/*`: install token or Stack session, team SSO and version policy, and
 * (for installs) UserDO's live grant check. VM installs are refused everywhere here except the
 * HostDO host socket, where TeamDO/CloudDO still restrict them to their own bound host.
 */

const refuse = (status: number, code: string, message: string) => Response.json({ error: { code, message } }, { status })

/**
 * The authenticated principal of a request, or the refusal to return. `token` comes from the
 * `bearer.` subprotocol (sockets) or the Authorization header (HTTP). `grants` resolves the
 * install's grant classes (owners other than UserDO cannot see UserDO's revocations).
 */
export const requestPrincipal = async (request: Request, env: Env, token: string | undefined, grants: boolean, otherTeam?: string, allowVmHost = false): Promise<Principal | Response> => {
  const authenticated = await authenticate(env, token)
  if (!authenticated?.user || !authenticated.team) return new Response("unauthenticated", { status: 401 })
  // A VM install has no general socket (review P1).  The phase-2 VM daemon is
  // the one exception: its own HostDO host socket is admitted later by
  // TeamDO/CloudDO after the machine/installation binding is checked.
  if (authenticated.install_kind === "vm" && !allowVmHost) return refuse(403, "auth.forbidden", "a VM install has no socket")
  // Team policy (P17-4): SSO (own team and the email domain's team), minimum client version for every connect.
  const rules = await signInRules(env, authenticated.team, authenticated.user)
  const gate = await ssoGate(env, authenticated)
  // The Stack session id and the install's email domain serve only this gate; owners never receive them.
  const { stack_session: _session, email_domain: _domain, ...authed } = gate.principal
  let refused = gate.refusal ?? versionRefusal(request.headers.get("x-cmux-client-version"), rules)
  // A socket into another team the user belongs to (`?team=`) passes that team's SSO and version policy too.
  if (!refused && otherTeam && otherTeam !== authenticated.team) {
    const other = await signInRules(env, otherTeam, authenticated.user)
    const p = gate.principal.kind === "session" && gate.principal.sso_team !== otherTeam ? await withSsoSession(env, gate.principal, otherTeam) : gate.principal
    refused = ssoRefusal(p, other, otherTeam) ?? versionRefusal(request.headers.get("x-cmux-client-version"), other)
  }
  if (refused) return Response.json({ error: refused }, { status: 403 })
  if (!grants) return authed
  const principal = await withGrantClasses(env, authed)
  if (!principal || (principal.install_kind === "vm" && !allowVmHost)) return new Response("forbidden", { status: 403 })
  return principal
}

export const bearerOfProtocols = (request: Request): string | undefined =>
  (request.headers.get("Sec-WebSocket-Protocol") ?? "")
    .split(",")
    .map((s) => s.trim())
    .find((p) => p.startsWith("bearer."))
    ?.slice("bearer.".length)

const bearerOfHeader = (request: Request): string | undefined => {
  const auth = request.headers.get("authorization") ?? ""
  return auth.startsWith("Bearer ") ? auth.slice(7) : undefined
}

/** Host ids TeamDO mints (`host_…`) and the catalog's `h_…`. */
export const HOST_PATH = /^\/v1\/wire\/host\/((?:host|h)_[A-Za-z0-9]{2,64})$/
const TEAM_ID = /^team_[A-Za-z0-9]{2,64}$/

/** `GET /v1/wire/host/<host>[?team=<team>]`: the HostDO control socket for the Mac or a device. */
export const handleHostWire = async (request: Request, env: Env, host: string): Promise<Response> => {
  const asked = new URL(request.url).searchParams.get("team") ?? undefined
  if (asked !== undefined && !TEAM_ID.test(asked)) return refuse(400, "validation.invalid", "team must be a team id")
  const principal = await requestPrincipal(request, env, bearerOfProtocols(request), true, asked, true)
  if (principal instanceof Response) return principal
  const team = asked ?? principal.team
  if (!team) return refuse(400, "validation.invalid", "team must be a team id")
  const access = await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).hostAccess(team, host, principal)
  if (!access) return refuse(403, "auth.forbidden", "not a host you may reach")
  const headers = new Headers(request.headers)
  headers.set("x-cmux-entity", host)
  headers.set("x-cmux-principal", JSON.stringify(principal))
  headers.set("x-cmux-ctl-role", access.role)
  headers.set("x-cmux-host-install", access.host.enrolled_by)
  headers.set("x-cmux-team", team)
  const stub = env.HOST_DO.get(env.HOST_DO.idFromName(host))
  return stub.fetch(new Request(request.url, { headers, method: "GET" }))
}

/** `POST /v1/realtime/turn {host?}`: short-lived Cloudflare Realtime TURN credentials for this install. */
export const handleTurn = async (request: Request, env: Env, fetcher: typeof fetch = fetch): Promise<Response> => {
  if (request.method !== "POST") return refuse(405, "validation.invalid", "POST only")
  const principal = await requestPrincipal(request, env, bearerOfHeader(request), true)
  if (principal instanceof Response) return principal
  const identity = principal.install ?? principal.identity
  if (!(await takeMobileRate(env.MOBILE_TURN_LIMIT, mobileRateKey("turn", identity), true)))
    return Response.json({ ok: false, error: { code: MOBILE_RATE_LIMITED, message: "too many TURN credential requests; retry shortly", retryable: true } }, { status: 429, headers: { "retry-after": String(MOBILE_RATE_RETRY_SECONDS), "cache-control": "no-store" } })
  const r = await mintTurnCredentials(env, identity, Date.now(), fetcher)
  if (!r.ok) return Response.json({ ok: false, error: { code: r.code, message: r.message, retryable: r.retryable } }, { status: 503 })
  return Response.json({ ok: true, value: r.value }, { headers: { "cache-control": "no-store" } })
}

/** `GET /v1/mobile/config`: the app's remote flags (C16). */
export const handleMobileConfig = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "GET") return refuse(405, "validation.invalid", "GET only")
  const principal = await requestPrincipal(request, env, bearerOfHeader(request), false)
  if (principal instanceof Response) return principal
  return Response.json({ ok: true, value: mobileConfig(env) }, { headers: { "cache-control": "private, max-age=300" } })
}
