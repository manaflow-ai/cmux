/**
 * Sign in with cmux: the console's half of an authorization-code + PKCE hand-off with cmux.com
 * (web/services/auth/consoleSignIn.ts is the other half).
 *
 * GET /auth/sign-in?return_to=/path  (startSignIn)
 *   Makes a random `state` and PKCE verifier, keeps them and the validated return path in a
 *   short-lived HttpOnly cookie on this origin, and sends the browser to cmux.com's sign-in.
 * GET /auth/handoff?code=...&state=...  (finishSignIn)
 *   Clears that cookie whatever happens, checks `state` against it, then redeems the one-time code
 *   server to server with the verifier and this console's client secret. The session cmux.com
 *   answers goes straight into the HttpOnly session cookies; the browser only ever carries the code.
 *
 * One flow cookie per browser: starting sign-in in a second tab replaces it, and the first tab's
 * return then fails closed to the generic "did not finish" page.
 *
 * No browser-only API and no framework import: the server routes and the tests both call this.
 */

/** The session cookies (server.ts reads them). __Host-: Secure, path=/, no Domain. */
export const ACCESS_COOKIE = "__Host-cmux_at"
export const REFRESH_COOKIE = "__Host-cmux_rt"
export const ACCESS_MAX_AGE_SECONDS = 60 * 60
export const REFRESH_MAX_AGE_SECONDS = 60 * 60 * 24 * 30

export const FLOW_COOKIE = "__Host-cmux_signin"
export const FLOW_TTL_SECONDS = 10 * 60
export const SIGN_IN_PATH = "/auth/sign-in"
export const HANDOFF_PATH = "/auth/handoff"
/** Where a failure with no flow of this browser's lands; the page says only that sign-in did not finish. */
export const FAILED_PATH = "/?signin=failed"
/**
 * The sign-in page after a failure, with a "try again" that keeps the flow's own return path (an
 * integration callback stays resumable). Nothing on it says which check failed.
 */
export const failedPath = (returnTo: string): string => {
  const safe = safeReturnPath(returnTo)
  return safe === "/" ? FAILED_PATH : `${FAILED_PATH}&return_to=${encodeURIComponent(safe)}`
}
const MAX_RETURN_PATH = 2048
/**
 * The longest return path kept (after percent-encoding). With the state and verifier it keeps the
 * flow cookie well under its 4096-character read limit and the browser's 4 KB cookie limit, so a
 * long URL can never drop the cookie and fail a sign-in that was otherwise valid.
 */
export const MAX_NORMALIZED_RETURN_PATH = 1800
/** cmux.com's one-time codes: 256 bits, base64url. */
const CODE_PATTERN = /^[A-Za-z0-9_-]{43}$/
const TOKEN_TIMEOUT_MS = 10_000

export type SignInConfig = {
  readonly clientId: string
  readonly redirectUri: string
  /** cmux.com's origin for this console. */
  readonly issuer: string
  readonly clientSecret: string
}

/** Each console signs in with the cmux.com deployment that shares its sign-in project. */
const CONSOLES: Readonly<Record<string, { clientId: string; issuer: string }>> = {
  "console.cmux.dev": { clientId: "cmux-console", issuer: "https://cmux.com" },
  "console-staging.cmux.dev": { clientId: "cmux-console-staging", issuer: "https://cmux-staging.vercel.app" }
}

/**
 * This console's client, or null (the flow is then off). The deployment pins its client with
 * CMUX_SIGN_IN_CLIENT_ID next to the one secret it holds, and the request's host must be that
 * client's console: a host header naming the other console never pairs this secret with it.
 */
export const signInConfig = (host: string | null | undefined, env: Record<string, string | undefined>): SignInConfig | null => {
  const name = host?.toLowerCase().split(":")[0] ?? ""
  const entry = CONSOLES[name]
  const pinned = env.CMUX_SIGN_IN_CLIENT_ID?.trim()
  const clientSecret = env.CMUX_SIGN_IN_CLIENT_SECRET?.trim()
  if (!entry || !pinned || entry.clientId !== pinned || !clientSecret || clientSecret.length < 32) return null
  return { clientId: entry.clientId, issuer: entry.issuer, redirectUri: `https://${name}${HANDOFF_PATH}`, clientSecret }
}

/**
 * A same-origin relative path, or "/". It must start with exactly one "/" (not "//" or "/\"),
 * carry no scheme, backslash, whitespace or control character (browsers drop tabs and newlines,
 * which would turn "/\t/x" into "//x"), stay on this origin when resolved, and not point back into
 * the sign-in routes.
 */
export const safeReturnPath = (raw: unknown): string => {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > MAX_RETURN_PATH) return "/"
  if (raw[0] !== "/" || raw[1] === "/" || raw[1] === "\\") return "/"
  if (/[\\\s\u0000-\u001f\u007f]/.test(raw)) return "/"
  try {
    const base = "https://console.invalid"
    const url = new URL(raw, base)
    if (url.origin !== base) return "/"
    if (url.pathname.startsWith("/auth/")) return "/"
    // The parsed form is percent-encoded ASCII, so it is always a valid Location header value.
    const normalized = `${url.pathname}${url.search}${url.hash}`
    if (normalized[1] === "/" || normalized[1] === "\\" || normalized.length > MAX_NORMALIZED_RETURN_PATH) return "/"
    return normalized
  } catch {
    return "/"
  }
}

const base64url = (bytes: Uint8Array): string => btoa(String.fromCharCode(...bytes)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_")

const randomToken = (bytes: number): string => base64url(crypto.getRandomValues(new Uint8Array(bytes)))

export const s256Challenge = async (verifier: string): Promise<string> =>
  base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))))

/** Constant-time string equality (compares SHA-256 digests, so lengths never leak through timing). */
export const constantTimeEqual = async (a: string, b: string): Promise<boolean> => {
  const [x, y] = await Promise.all([a, b].map(async (s) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))))
  let diff = 0
  for (let i = 0; i < x!.length; i++) diff |= x![i]! ^ y![i]!
  return diff === 0
}

type FlowCookie = { readonly state: string; readonly verifier: string; readonly returnTo: string; readonly expiresAt: number }

const encodeFlow = (flow: FlowCookie): string => base64url(new TextEncoder().encode(JSON.stringify(flow)))

const decodeFlow = (value: string | undefined, now: number): FlowCookie | null => {
  if (!value || value.length > 4096) return null
  try {
    const json = new TextDecoder().decode(Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0)))
    const flow = JSON.parse(json) as Partial<FlowCookie>
    if (typeof flow.state !== "string" || typeof flow.verifier !== "string" || typeof flow.returnTo !== "string" || typeof flow.expiresAt !== "number") return null
    if (flow.expiresAt <= now) return null
    return { state: flow.state, verifier: flow.verifier, returnTo: flow.returnTo, expiresAt: flow.expiresAt }
  } catch {
    return null
  }
}

export const readCookie = (request: Request, name: string): string | undefined => {
  for (const part of (request.headers.get("cookie") ?? "").split(";")) {
    const index = part.indexOf("=")
    if (index < 0) continue
    if (part.slice(0, index).trim() === name) return part.slice(index + 1).trim()
  }
  return undefined
}

export const cookieHeader = (name: string, value: string, maxAge: number): string => `${name}=${value}; Path=/; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Lax`

const redirect = (location: string, cookies: readonly string[]): Response => {
  const headers = new Headers({ location, "cache-control": "no-store", "referrer-policy": "no-referrer" })
  for (const cookie of cookies) headers.append("set-cookie", cookie)
  return new Response(null, { status: 303, headers })
}

export type StartDeps = { readonly config: SignInConfig | null; readonly now?: () => number }

export const startSignIn = async (request: Request, deps: StartDeps): Promise<Response> => {
  const config = deps.config
  if (!config) return redirect(FAILED_PATH, [])
  const now = deps.now?.() ?? Date.now()
  const flow: FlowCookie = {
    // 256 bits each; the state is checked on return, the verifier never leaves this server but in the redeem POST.
    state: randomToken(32),
    verifier: randomToken(32),
    returnTo: safeReturnPath(new URL(request.url).searchParams.get("return_to")),
    expiresAt: now + FLOW_TTL_SECONDS * 1000
  }
  const target = new URL("/handler/console-sign-in", config.issuer)
  target.searchParams.set("client_id", config.clientId)
  target.searchParams.set("state", flow.state)
  target.searchParams.set("code_challenge", await s256Challenge(flow.verifier))
  target.searchParams.set("code_challenge_method", "S256")
  return redirect(target.toString(), [cookieHeader(FLOW_COOKIE, encodeFlow(flow), FLOW_TTL_SECONDS)])
}

export type FinishDeps = {
  readonly config: SignInConfig | null
  readonly fetch: typeof fetch
  readonly now?: () => number
  /** Server log line for a refusal: the reason category only, never a code, state or token. */
  readonly log?: (reason: string) => void
}

type TokenAnswer = { readonly ok: true; readonly access: string; readonly refresh: string } | { readonly ok: false }

const redeem = async (config: SignInConfig, code: string, verifier: string, fetchImpl: typeof fetch): Promise<TokenAnswer> => {
  try {
    const res = await fetchImpl(new URL("/handler/console-sign-in/token", config.issuer).toString(), {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ client_id: config.clientId, client_secret: config.clientSecret, code, code_verifier: verifier, redirect_uri: config.redirectUri }),
      redirect: "error",
      signal: AbortSignal.timeout(TOKEN_TIMEOUT_MS)
    })
    if (!res.ok) return { ok: false }
    const body = (await res.json()) as { access_token?: unknown; refresh_token?: unknown }
    if (typeof body.access_token !== "string" || typeof body.refresh_token !== "string" || !body.access_token || !body.refresh_token) return { ok: false }
    return { ok: true, access: body.access_token, refresh: body.refresh_token }
  } catch {
    return { ok: false }
  }
}

export const finishSignIn = async (request: Request, deps: FinishDeps): Promise<Response> => {
  const clearFlow = cookieHeader(FLOW_COOKIE, "", 0)
  // Set once this browser's own flow cookie is read: a failure then offers a retry to the same page.
  let returnTo = "/"
  const fail = (reason: string) => {
    deps.log?.(reason)
    return redirect(failedPath(returnTo), [clearFlow])
  }
  const config = deps.config
  if (!config) return fail("not_configured")
  const params = new URL(request.url).searchParams
  const code = params.get("code") ?? ""
  const state = params.get("state") ?? ""
  const flow = decodeFlow(readCookie(request, FLOW_COOKIE), deps.now?.() ?? Date.now())
  if (flow) returnTo = flow.returnTo
  if (!flow || !state || !(await constantTimeEqual(flow.state, state))) {
    // Not a flow this browser started: burn the code (a wrong verifier consumes it on cmux.com) so
    // a code that reached the wrong browser cannot be replayed elsewhere.
    // Only a well-formed code (cmux.com's format) is worth a request.
    if (CODE_PATTERN.test(code)) await redeem(config, code, randomToken(32), deps.fetch)
    return fail("state")
  }
  if (!code) return fail("code")
  const answer = await redeem(config, code, flow.verifier, deps.fetch)
  if (!answer.ok) return fail("redeem")
  return redirect(safeReturnPath(flow.returnTo), [
    clearFlow,
    // Encoded the way server.ts's setCookie writes them, so its getCookie reads them back.
    cookieHeader(ACCESS_COOKIE, encodeURIComponent(answer.access), ACCESS_MAX_AGE_SECONDS),
    cookieHeader(REFRESH_COOKIE, encodeURIComponent(answer.refresh), REFRESH_MAX_AGE_SECONDS)
  ])
}
