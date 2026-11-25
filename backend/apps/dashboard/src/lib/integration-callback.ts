import { callbackSearch } from "./search"

/**
 * Reads only the team claim from an integration state's JWT for request routing.
 *
 * The state is signed by the API and remains opaque to the dashboard. This hint
 * is deliberately untrusted: the API verifies the signature, user, connection
 * and team again when it handles integration.complete.
 */
export const integrationTeamHint = (state: string | undefined): string | undefined => {
  const team = unverifiedStateClaims(state)?.team
  return typeof team === "string" && /^team_[0-9a-f]{20}$/.test(team) ? team : undefined
}

/** The state JWT's payload, decoded without verification (routing hints only). */
const unverifiedStateClaims = (state: string | undefined): Record<string, unknown> | undefined => {
  if (typeof state !== "string" || !state || state.length > 4096) return undefined
  const parts = state.split(".")
  if (parts.length !== 3) return undefined
  return jsonPart(parts[1]!)
}

const base64UrlBytes = (part: string) => {
  const encoded = part.replace(/-/g, "+").replace(/_/g, "/")
  return Uint8Array.from(atob(encoded + "=".repeat((4 - (encoded.length % 4)) % 4)), (c) => c.charCodeAt(0))
}

/** One base64url JWT part as a JSON object; undefined for anything else. */
const jsonPart = (part: string): Record<string, unknown> | undefined => {
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(base64UrlBytes(part)))
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined
  } catch {
    return undefined
  }
}

/**
 * The API environment that signed an integration state, from its issuer `https://cmux-api/<environment>`
 * (api src/integrations/state.ts). Untrusted, like the team hint: it only picks which API to ask, and that
 * API verifies the signature and issuer again.
 */
export const integrationEnvironmentHint = (state: string | undefined): string | undefined => {
  const iss = unverifiedStateClaims(state)?.iss
  const env = typeof iss === "string" ? /^https:\/\/cmux-api\/([a-z0-9-]{1,40})$/.exec(iss)?.[1] : undefined
  return env
}

/**
 * The development API Worker has no hosted console of its own. Its Connect redirects (wrangler.jsonc
 * env.development INTEGRATIONS_CALLBACK_ORIGIN) come back to the staging console, which signs in through
 * the same sign-in project, and this console sends that completion on to the development API.
 * Only the staging console does this: on any other console a development state goes to the console's own
 * API, which refuses it. test-server/integration-callback-route.test.ts pins both URLs to wrangler.jsonc.
 */
export const STAGING_API_URL = "https://cloud-api-staging.cmux.dev"
export const STAGING_CONSOLE_HOST = "console-staging.cmux.dev"
export const DEVELOPMENT_API_URL = "https://cmux-api-development.debussy.workers.dev"

/**
 * Which API finishes this completion: the console's own, or (staging console, development state) the development API.
 * The staging console is recognised by its API or by its own host, so a console API URL in another form still forwards.
 */
export const integrationCompletionApi = (at: { readonly api: string; readonly host?: string }, state: string | undefined): { readonly url: string; readonly environment?: "development" } => {
  const api = at.api.replace(/\/$/, "")
  const staging = api === STAGING_API_URL || at.host?.toLowerCase() === STAGING_CONSOLE_HOST
  return staging && integrationEnvironmentHint(state) === "development" ? { url: DEVELOPMENT_API_URL, environment: "development" } : { url: api }
}

/** The development API's state issuer and the audience every integration state carries (api src/integrations/state.ts). */
export const DEVELOPMENT_STATE_ISSUER = "https://cmux-api/development"
const STATE_AUDIENCE = "cmux-integration-state"

/**
 * Whether `state` is an unexpired integration state the development API (`issuer`, the keys in `jwks`) signed
 * (ES256) for `user`, the console session's own person. The staging console asks this before it sends a session
 * to the development API: the issuer alone is a claim anyone can write into a link, and a genuine state made for
 * someone else is a link anyone can send. The API still verifies the state, its user and its team when it completes.
 */
export const integrationStateSignedBy = async (state: string | undefined, jwks: unknown, expect: { readonly issuer: string; readonly user: string }, now: number = Date.now()): Promise<boolean> => {
  if (typeof state !== "string" || state.length > 4096) return false
  const parts = state.split(".")
  if (parts.length !== 3) return false
  const claims = jsonPart(parts[1]!)
  if (jsonPart(parts[0]!)?.alg !== "ES256" || !claims) return false
  if (claims.iss !== expect.issuer || claims.aud !== STATE_AUDIENCE) return false
  if (!expect.user || claims.sub !== expect.user) return false
  if (typeof claims.exp !== "number" || claims.exp * 1000 <= now) return false
  const keys = (jwks as { keys?: unknown } | null | undefined)?.keys
  if (!Array.isArray(keys)) return false
  try {
    const signature = base64UrlBytes(parts[2]!)
    const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`)
    for (const jwk of keys.slice(0, 8)) {
      const { kty, crv, x, y } = (jwk ?? {}) as Record<string, unknown>
      if (kty !== "EC" || crv !== "P-256" || typeof x !== "string" || typeof y !== "string") continue
      const key = await crypto.subtle.importKey("jwk", { kty, crv, x, y }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"])
      if (await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature, signed)) return true
    }
  } catch {
    return false
  }
  return false
}

/**
 * The subject of the console's own access token, and whether the token is still good for a call (30 s of slack).
 * Read without verification: the token is the console's own HttpOnly cookie, and the answer only decides whether
 * that same person's session is sent on. Undefined when the token carries no subject.
 */
export const accessTokenSubject = (token: string | undefined, now: number = Date.now()): { readonly subject: string; readonly fresh: boolean } | undefined => {
  const parts = typeof token === "string" && token.length <= 16_384 ? token.split(".") : []
  const claims = parts.length === 3 ? jsonPart(parts[1]!) : undefined
  if (!claims || typeof claims.sub !== "string" || !claims.sub) return undefined
  return { subject: claims.sub, fresh: typeof claims.exp === "number" && claims.exp * 1000 > now + 30_000 }
}

/**
 * The API's id for a signed-in person, as it writes it into a state's subject (api src/domains/user.ts userIdFor;
 * api test-node/dev-github-app.test.ts pins the two equal).
 */
export const apiUserId = async (signInProject: string, subject: string): Promise<string> => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`stack:${signInProject}:${subject}`)))
  return `user_${Array.from(digest.slice(0, 10), (b) => b.toString(16).padStart(2, "0")).join("")}`
}

/**
 * The answer for a development completion the development API refused to authenticate. A 401 from the console's
 * own API means the session ended; from the development API it means that API did not accept this sign-in, and
 * the console's session is still good, so the page must not show "sign in".
 */
export const developmentRefusal = (status: number): { readonly code: string; readonly message: string } | undefined =>
  status === 401
    ? { code: "auth.development_refused", message: "The development Cloud did not accept this sign-in. Start the connection again from a development build signed in to this account." }
    : undefined

/** The `ret` claim of an integration state's JWT, unverified (the API verifies the state when the app completes it). */
const stateReturnHint = (state: string | undefined): string | undefined => {
  const ret = unverifiedStateClaims(state)?.ret
  return typeof ret === "string" ? ret : undefined
}

/**
 * A connect the app started (#46018): the state's return link is the app's own `<scheme>://integration/complete`.
 * The provider's redirect goes straight on to it with `state`, `code`, `installation_id`, `setup_action` and `error`,
 * and the app finishes the connection with its own sign-in: no page here, no web session. Undefined for any other
 * connect (one started here, or from a chat), which this page finishes as before. The link is only a hint read from
 * the unverified state: the app sends the state back, and the API completes only a state signed for that person.
 */
export const integrationAppHandoff = (search: {
  state?: string
  code?: string
  installation_id?: string
  setup_action?: string
  error?: string
}): string | undefined => {
  // The API would not sign this connect on (AUTHORIZE_REFUSED): the app reads any `error` as a cancel and says
  // nothing, so this one stays here, where the page tells the person to start again.
  if (search.error === AUTHORIZE_REFUSED) return undefined
  const ret = stateReturnHint(search.state)
  if (!ret || ret.length > 512 || !RETURN_TO_PATTERN.test(ret) || !ret.endsWith("://integration/complete")) return undefined
  const query = new URLSearchParams()
  for (const key of ["state", "code", "installation_id", "setup_action", "error"] as const) {
    const value = search[key]
    if (value) query.set(key, value)
  }
  return `${ret}?${query.toString()}`
}

/**
 * The callback request's answer when it is an app handoff (``integrationAppHandoff``): a plain 302 to the app's link,
 * sent by the route's server handler before the router runs. The router's own `redirect()` allows only http(s) and a
 * few other schemes, so a `cmux://` redirect thrown from `beforeLoad` fails the whole render (HTTP 500) instead.
 * Undefined for any other callback, which the page renders and finishes as before.
 */
export const integrationAppHandoffResponse = (url: string): Response | undefined => {
  const search = Object.fromEntries(new URL(url).searchParams)
  const handoff = integrationAppHandoff(callbackSearch(search))
  if (!handoff) return undefined
  // The query carries GitHub's one-time code: not cached, and not sent on as a referrer.
  return new Response(null, { status: 302, headers: { Location: handoff, "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" } })
}

/** The API route that sends a code-less GitHub redirect on to GitHub's authorize page (api src/integrations/github-authorize-route.ts). */
export const GITHUB_AUTHORIZE_PATH = "/v1/integrations/github/authorize"
/** The `error` that route sends back here for a state it would not sign again (expired, or not its own). */
export const AUTHORIZE_REFUSED = "connection_link_expired"

/**
 * GitHub's redirect after a person saves an installation that already existed: `installation_id` and
 * `setup_action=update`, and no `code`. Connect opens the App's install page, and for an account that already has the
 * App GitHub shows that installation's settings instead. Without a code nobody can finish the connection (the code is
 * what proves who the GitHub user is), so the browser goes on to the API, which sends it through GitHub's authorize
 * page with the installation named in the state; GitHub then comes back here with a code. Checked before the app
 * hand-off: the app could only be refused. `api` is asked for only when the answer is a redirect.
 *
 * Undefined for every other callback: one with a code, a cancelled one (`error`), an organization's install request
 * (`setup_action=request`, which has no installation to authorize), and another provider's. GitHub's authorize page
 * returns a code or an error and never an installation, so this cannot send the same connect round twice.
 */
export const integrationAuthorizeBounce = (url: string, at: { readonly api: () => string; readonly host?: string | null }): Response | undefined => {
  const search = callbackSearch(Object.fromEntries(new URL(url).searchParams))
  if (!search.state || !search.installation_id || search.code || search.error || search.setup_action === "request") return undefined
  if (unverifiedStateClaims(search.state)?.provider !== "github") return undefined
  const api = integrationCompletionApi({ api: at.api(), ...(at.host ? { host: at.host } : {}) }, search.state).url
  const query = new URLSearchParams({ state: search.state, installation_id: search.installation_id })
  return new Response(null, { status: 302, headers: { Location: `${api}${GITHUB_AUTHORIZE_PATH}?${query}`, "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" } })
}

/**
 * GitHub's redirect after a person saved an existing installation's settings page directly (its Setup URL):
 * `installation_id`, `setup_action=update`, and no `state`, because no connect started it. (A fresh install from the
 * App's public page, `setup_action=install` with no state, is linked to no team yet, so it keeps the page's own answer.) Nothing is left to finish here, and nobody needs to
 * sign in to this page: the API hears the change from GitHub itself, and the cmux app reads GitHub again (#55104). The
 * page says so instead of asking for a sign-in that could not help.
 */
export const integrationSavedOnGitHub = (search: { state?: string; installation_id?: string; setup_action?: string; error?: string }): boolean =>
  !search.state && !search.error && !!search.installation_id && /^[0-9]{1,20}$/.test(search.installation_id) && search.setup_action === "update"

export const integrationCompletionRequest = (state: string, extra: { code?: string; installation_id?: string; setup_action?: string } = {}) => ({
  params: {
    state,
    ...(extra.code ? { code: extra.code } : {}),
    ...(extra.installation_id ? { installation_id: extra.installation_id } : {}),
    ...(extra.setup_action ? { setup_action: extra.setup_action } : {}),
  },
  team: integrationTeamHint(state),
  idempotency_key: `complete:${state.slice(-40)}`,
})

const RETURN_HEX = "[0-9a-f]{32}"
const RETURN_SESSION = "[A-Za-z0-9._-]{1,200}"
const RETURN_HINT = "(?:host|name|message)=[A-Za-z0-9._:%-]{1,128}"
/**
 * The cmux chat links a connect may return to: the same grammar as `CONNECT_RETURN_TO` in
 * @cmux/protocol (a test pins them equal). Checked again here, before the browser leaves the dashboard.
 */
export const RETURN_TO_PATTERN = new RegExp(
  `^(?:cmux|cmux-nightly|cmux-rc|cmux-dev(?:-[a-z0-9-]{1,40})?)://(?:` +
    `(?:workspace/ws_|pane/pane_|tab/tab_)${RETURN_HEX}(?:\\?machine=machine_${RETURN_HEX})?` +
    `|session/${RETURN_SESSION}(?:\\?machine=machine_${RETURN_HEX})?(?:#turn-${RETURN_SESSION})?` +
    `|agent/[a-z0-9-]{1,64}/[A-Za-z0-9._:-]{1,256}(?:\\?${RETURN_HINT}(?:&${RETURN_HINT}){0,2})?` +
    `|integration/complete` +
    `)$`,
)

/** The chat link a completed connect returns to, from the API's completion answer; anything else is dropped. */
export const integrationReturnLink = (value: unknown): string | undefined => {
  const link = (value as { return_to?: unknown } | null | undefined)?.return_to
  return typeof link === "string" && link.length <= 512 && RETURN_TO_PATTERN.test(link) ? link : undefined
}

/** An installation's settings page on GitHub (the API's `GITHUB_CONFIGURE_URL`). */
export const CONFIGURE_URL_PATTERN = /^https:\/\/github\.com\/(?:organizations\/[A-Za-z0-9-]{1,39}\/)?settings\/installations\/[0-9]{1,20}$/

/** The GitHub page to add the asked repository on, when the completion says the link left it out. */
export const integrationConfigureLink = (value: unknown): string | undefined => {
  const link = (value as { configure_url?: unknown } | null | undefined)?.configure_url
  return typeof link === "string" && CONFIGURE_URL_PATTERN.test(link) ? link : undefined
}
