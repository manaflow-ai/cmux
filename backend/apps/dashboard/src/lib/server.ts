import { createServerFn, createServerOnlyFn } from "@tanstack/react-start"
import { deleteCookie, getCookie, getRequestHeader, setCookie } from "@tanstack/react-start/server"
import { teamHeaders } from "./team-scope"

/**
 * Server functions. They call only the cmux API Worker and Stack Auth's client
 * REST API (sign-in, refresh); never a database (spec D1).
 *
 * Session: the Stack access and refresh tokens live in HttpOnly, Secure,
 * SameSite=Lax cookies set here. Browser code never reads them; server
 * functions forward the access token to the API as the bearer and refresh it
 * once on a 401.
 */

// __Host- names: Secure, path=/, no Domain, so sibling *.cmux.dev hosts cannot plant or read them.
const ACCESS = "__Host-cmux_at"
const REFRESH = "__Host-cmux_rt"

/**
 * CSRF: SameSite=Lax still lets a sibling *.cmux.dev page POST here (same site), so every
 * state-changing server function requires an Origin equal to this host.
 */
export const requireSameOrigin = createServerOnlyFn(() => {
  const origin = getRequestHeader("origin")
  const host = getRequestHeader("x-forwarded-host") ?? getRequestHeader("host")
  if (!origin || !host || new URL(origin).host !== host) throw new Error("cross-origin request refused")
})
const cookieBase = { httpOnly: true, secure: true, sameSite: "lax" as const, path: "/" }

export const apiUrl = createServerOnlyFn(() => {
  const url = process.env.CMUX_API_URL
  if (!url) throw new Error("CMUX_API_URL is not set")
  return url.replace(/\/$/, "")
})

const stackHeaders = () => {
  const project = process.env.CMUX_STACK_PROJECT_ID
  // The publishable key is optional: the production project requires none,
  // and a revoked key is refused.
  const key = process.env.CMUX_STACK_PUBLISHABLE_CLIENT_KEY?.trim()
  if (!project) throw new Error("Stack project is not configured")
  return {
    "content-type": "application/json",
    "x-stack-project-id": project,
    ...(key ? { "x-stack-publishable-client-key": key } : {}),
    "x-stack-access-type": "client"
  }
}

const setSession = (access: string, refresh?: string) => {
  // Stack access tokens live about 10 minutes; the cookie never outlives the token by much.
  setCookie(ACCESS, access, { ...cookieBase, maxAge: 60 * 60 })
  if (refresh) setCookie(REFRESH, refresh, { ...cookieBase, maxAge: 60 * 60 * 24 * 30 })
}

const clearSession = () => {
  deleteCookie(ACCESS, cookieBase)
  deleteCookie(REFRESH, cookieBase)
}

export const signIn = createServerFn({ method: "POST" })
  .validator((d: { email: string; password: string }) => d)
  .handler(async ({ data }): Promise<{ ok: true } | { error: string }> => {
    requireSameOrigin()
    const res = await fetch("https://api.stack-auth.com/api/v1/auth/password/sign-in", {
      method: "POST",
      headers: stackHeaders(),
      body: JSON.stringify({ email: data.email, password: data.password })
    })
    const body = (await res.json()) as { access_token?: string; refresh_token?: string; error?: string; code?: string }
    if (!res.ok || !body.access_token || !body.refresh_token) return { error: body.code ?? body.error ?? `sign-in failed (${res.status})` }
    setSession(body.access_token, body.refresh_token)
    return { ok: true }
  })

export const signOut = createServerFn({ method: "POST" }).handler(async () => {
    requireSameOrigin()
  clearSession()
  return { ok: true }
})

/** Whether a session cookie exists (the browser cannot read HttpOnly cookies itself). */
export const sessionState = createServerFn({ method: "GET" }).handler(async () => ({ signedIn: Boolean(getCookie(REFRESH) ?? getCookie(ACCESS)) }))

const refreshAccess = async (): Promise<string | undefined> => {
  const rt = getCookie(REFRESH)
  if (!rt) return undefined
  const res = await fetch("https://api.stack-auth.com/api/v1/auth/sessions/current/refresh", {
    method: "POST",
    headers: { ...stackHeaders(), "x-stack-refresh-token": rt },
    body: "{}"
  })
  const body = (await res.json().catch(() => ({}))) as { access_token?: string }
  if (!res.ok || !body.access_token) {
    clearSession()
    return undefined
  }
  setSession(body.access_token)
  return body.access_token
}

/** JSON as it crosses the server-function boundary. */
export type Json = string | number | boolean | null | Array<Json> | { [k: string]: Json }

export interface OpResponse {
  readonly ok: boolean
  readonly op: string
  readonly value?: Json
  readonly error?: { code: string; message: string; retryable: boolean }
  readonly transaction: string
  readonly idempotency_key: string
  readonly revision?: string
  readonly replayed: boolean
  readonly stream: string
  readonly sequence: number
}

export type ApiResult<T> = { readonly status: number; readonly body: T }

/**
 * POSTs to the API with the cookie's access token; refreshes once on a missing token or a 401.
 * `team` (cx-5xew) names the team to act in (x-cmux-team); the API checks the membership.
 */
const postImpl = <T,>(path: string, payload: unknown, team?: string): Promise<ApiResult<T>> => callImpl<T>("POST", path, payload, team)

/** One API call with the cookie's access token (GET sends no body); refreshes once on a missing token or a 401. */
const callImpl = async <T,>(method: "GET" | "POST" | "PUT", path: string, payload: unknown, team?: string): Promise<ApiResult<T>> => {
  const send = async (token: string) => {
    const res = await fetch(`${apiUrl()}${path}`, {
      method,
      headers: { ...(method !== "GET" ? { "content-type": "application/json" } : {}), authorization: `Bearer ${token}`, ...teamHeaders(team) },
      ...(method !== "GET" ? { body: JSON.stringify(payload) } : {})
    })
    return { status: res.status, body: (await res.json().catch(() => ({}))) as T }
  }
  const at = getCookie(ACCESS)
  if (at) {
    const first = await send(at)
    if (first.status !== 401) return first
  }
  const fresh = await refreshAccess()
  if (!fresh) return { status: 401, body: { error: "signed out" } as T }
  return send(fresh)
}

/** Server-only: an API call with the session cookie (refreshes once on 401). */
export const post = createServerOnlyFn(postImpl)

export const mutate = createServerFn({ method: "POST" })
  .validator((d: { op: string; params: Record<string, unknown>; idempotency_key: string; team?: string }) => d)
  .handler(async ({ data }) => {
    requireSameOrigin()
    return post<OpResponse>("/v1/ops", { op: data.op, params: data.params, idempotency_key: data.idempotency_key, origin: "user" }, data.team)
  })

/**
 * team_vm.retired.export (cx-lyvg): sends the op with the session, then answers the absolute
 * download URL on the API origin (single use, 5 minutes) for the browser to open; null on failure.
 */
export const exportTeamFiles = createServerFn({ method: "POST" })
  .validator((d: { vm: string; idempotency_key: string; team?: string }) => d)
  .handler(async ({ data }) => {
    requireSameOrigin()
    const r = await post<OpResponse>("/v1/ops", { op: "team_vm.retired.export", params: { vm: data.vm }, idempotency_key: data.idempotency_key, origin: "user" }, data.team)
    const value = r.body.ok && r.body.value && typeof r.body.value === "object" && !Array.isArray(r.body.value) ? r.body.value : null
    const path = value && typeof value.path === "string" && value.path.startsWith("/v1/team-vm/export/") ? value.path : null
    return { ...r, url: path ? `${apiUrl()}${path}` : null }
  })

export const read = createServerFn({ method: "POST" })
  .validator((d: { op: string; params: Record<string, unknown>; team?: string }) => d)
  .handler(async ({ data }) => {
    requireSameOrigin()
    return post<{ op: string; value: Json; stream: string; revision: string }>("/v1/read", { op: data.op, params: data.params }, data.team)
  })

/**
 * The credential subprotocol for the live WebSocket panel. Browsers cannot attach cookies or
 * headers to a cross-origin WebSocket handshake, and Workers invocation logs record every
 * header but Authorization (cx-dgsp). So this server function mints a single-use ticket
 * (POST /v1/wire/ticket, 30 s, user socket only) with the cookie's access token, and page script sees only the
 * ticket, never the token. Without a ticket the panel gets no credential: the legacy
 * `bearer.<access token>` subprotocol is retired.
 */
export const wireCredential = createServerFn({ method: "POST" }).handler(async (): Promise<{ protocol: string | null; apiUrl: string }> => {
  requireSameOrigin()
  // The panel opens /v1/wire/user (hooks.ts useWire); the ticket opens no other socket.
  const minted = await postImpl<{ ticket?: string }>("/v1/wire/ticket", { scope: "user" })
  if (minted.status === 200 && typeof minted.body.ticket === "string") return { protocol: `ticket.${minted.body.ticket}`, apiUrl: apiUrl() }
  return { protocol: null, apiUrl: apiUrl() }
})

/** GET /v1/billing/summary for the team in the URL: the billing page's one read (paid-plans-DESIGN.md §3). */
export const billingSummary = createServerFn({ method: "POST" })
  .validator((d: { team?: string }) => d)
  .handler(async ({ data }) => {
    requireSameOrigin()
    return callImpl<{ ok: boolean; value?: Json; error?: { code: string; message: string } }>("GET", "/v1/billing/summary", null, data.team)
  })

/** POST /v1/credits/topup: a test-mode payment page for `usd` of credits; the browser opens the answered URL. */
export const creditsTopup = createServerFn({ method: "POST" })
  .validator((d: { usd: number; team?: string }) => d)
  .handler(async ({ data }) => {
    requireSameOrigin()
    return callImpl<{ ok: boolean; value?: { url: string }; error?: { code: string; message: string } }>("POST", "/v1/credits/topup", { usd: data.usd }, data.team)
  })

/** GET or PUT /v1/credits/auto-reload (paid-plans-DESIGN.md §6.3); `settings` absent reads. */
export const creditsAutoReload = createServerFn({ method: "POST" })
  .validator((d: { team?: string; settings?: { enabled: boolean; threshold_usd: number; amount_usd: number; monthly_cap_usd: number } }) => d)
  .handler(async ({ data }) => {
    requireSameOrigin()
    if (!data.settings) return callImpl<{ ok: boolean; value?: Json; error?: { code: string; message: string } }>("GET", "/v1/credits/auto-reload", null, data.team)
    const s = data.settings
    if (s.amount_usd <= 0 || s.monthly_cap_usd <= 0) return { status: 400, body: { ok: false, error: { code: "validation.invalid", message: "amounts" } } }
    return callImpl<{ ok: boolean; value?: Json; error?: { code: string; message: string } }>("PUT", "/v1/credits/auto-reload", s, data.team)
  })
