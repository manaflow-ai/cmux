import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { accessTokenSubject, apiUserId, integrationAppHandoffResponse, DEVELOPMENT_API_URL, DEVELOPMENT_STATE_ISSUER, developmentRefusal, integrationCompletionApi, integrationEnvironmentHint, integrationStateSignedBy, STAGING_API_URL, STAGING_CONSOLE_HOST } from "../src/lib/integration-callback"
import { AUTHORIZE_REFUSED, GITHUB_AUTHORIZE_PATH, integrationAuthorizeBounce } from "../src/lib/integration-callback"

/**
 * The development Worker's Connect comes back to the staging console, which finishes development states on the
 * development API (src/lib/integration-callback.ts integrationCompletionApi). That holds only while the two
 * deployments agree, so this pins the dashboard's URLs to the API's wrangler.jsonc.
 */

/** JSONC to JSON: drops comments outside strings (wrangler.jsonc has no trailing commas). */
const stripComments = (text: string): string => {
  let out = ""
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!
    if (c === '"') {
      let j = i + 1
      while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1
      out += text.slice(i, j + 1)
      i = j
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++
      out += "\n"
    } else out += c
  }
  return out
}

const token = (payload: unknown) =>
  `header.${btoa(JSON.stringify(payload)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")}.signature`

type Vars = Record<string, string>
const wrangler = JSON.parse(stripComments(readFileSync(join(import.meta.dir, "../../api/wrangler.jsonc"), "utf8"))) as { env: Record<string, { vars: Vars }> }
const development = wrangler.env.development!.vars
const staging = wrangler.env.staging!.vars

test("development Connect comes back to the staging console", () => {
  expect(development.INTEGRATIONS_CALLBACK_ORIGIN).toBe(staging.DASHBOARD_ORIGIN)
  // Pairing and SSO keep the development DASHBOARD_ORIGIN.
  expect(development.DASHBOARD_ORIGIN).not.toBe(staging.DASHBOARD_ORIGIN)
  expect(staging.INTEGRATIONS_CALLBACK_ORIGIN).toBeUndefined()
  expect(wrangler.env.production!.vars.INTEGRATIONS_CALLBACK_ORIGIN).toBeUndefined()
})

test("the staging console's session is valid on the development API", () => {
  // One sign-in project: the staging console's access token is a development token too.
  expect(development.STACK_PROJECT_ID).toBe(staging.STACK_PROJECT_ID)
})

test("the console routes to the deployed API origins", () => {
  expect(STAGING_API_URL).toBe(staging.CLOUD_API_ORIGIN!)
  expect(`https://${STAGING_CONSOLE_HOST}`).toBe(staging.DASHBOARD_ORIGIN!)
  expect(DEVELOPMENT_API_URL).toBe(development.CLOUD_API_ORIGIN!)
})

test("reads the signing environment from the state issuer only", () => {
  expect(integrationEnvironmentHint(token({ iss: "https://cmux-api/development" }))).toBe("development")
  expect(integrationEnvironmentHint(token({ iss: "https://cmux-api/staging" }))).toBe("staging")
  for (const iss of ["https://evil.example/development", "https://cmux-api/development/x", "https://cmux-api/", 42]) {
    expect(integrationEnvironmentHint(token({ iss }))).toBeUndefined()
  }
  expect(integrationEnvironmentHint("not-a-jwt")).toBeUndefined()
})

test("only the staging console sends a development state to the development API", () => {
  const dev = token({ iss: "https://cmux-api/development", team: "team_0123456789abcdef0123" })
  const staging = token({ iss: "https://cmux-api/staging", team: "team_0123456789abcdef0123" })
  expect(integrationCompletionApi({ api: `${STAGING_API_URL}/` }, dev)).toEqual({ url: DEVELOPMENT_API_URL, environment: "development" })
  // The staging console by its host, whatever form its API URL takes.
  expect(integrationCompletionApi({ api: "https://cmux-api-staging.example.workers.dev", host: STAGING_CONSOLE_HOST }, dev)).toEqual({ url: DEVELOPMENT_API_URL, environment: "development" })
  expect(integrationCompletionApi({ api: STAGING_API_URL, host: STAGING_CONSOLE_HOST }, staging)).toEqual({ url: STAGING_API_URL })
  expect(integrationCompletionApi({ api: STAGING_API_URL }, "not-a-jwt")).toEqual({ url: STAGING_API_URL })
  // The production console never forwards a session to a lower environment.
  expect(integrationCompletionApi({ api: "https://cloud-api.cmux.dev", host: "console.cmux.dev" }, dev)).toEqual({ url: "https://cloud-api.cmux.dev" })
})

const b64url = (bytes: Uint8Array | string): string =>
  btoa(typeof bytes === "string" ? bytes : String.fromCharCode(...bytes)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")

/** A real ES256 JWT, signed the way the API signs a state (api src/integrations/state.ts signState). */
const signedState = async (key: CryptoKey, claims: Record<string, unknown>, header: Record<string, unknown> = { alg: "ES256", typ: "JWT" }): Promise<string> => {
  const signed = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signed))
  return `${signed}.${b64url(new Uint8Array(signature))}`
}

const keyPair = async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey)
  // The shape of the API's /.well-known/jwks.json (api src/auth.ts publicJwks).
  return { key: pair.privateKey, jwks: { keys: [{ kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, kid: "development-test", alg: "ES256", use: "sig" }] } }
}

test("a development state is forwarded only when the development API's key signed it for this person", async () => {
  const development = await keyPair()
  const other = await keyPair()
  const now = Date.UTC(2026, 10, 18)
  const me = await apiUserId("project", "stack-user-1")
  const expect_ = { issuer: DEVELOPMENT_STATE_ISSUER, user: me }
  const claims = { iss: DEVELOPMENT_STATE_ISSUER, aud: "cmux-integration-state", sub: me, team: "team_0123456789abcdef0123", exp: now / 1000 + 600 }
  const good = await signedState(development.key, claims)
  expect(await integrationStateSignedBy(good, development.jwks, expect_, now)).toBe(true)
  // The issuer hint alone (what a hand-made link can carry) is not enough.
  expect(integrationEnvironmentHint(token({ iss: DEVELOPMENT_STATE_ISSUER }))).toBe("development")
  expect(await integrationStateSignedBy(token({ ...claims }), development.jwks, expect_, now)).toBe(false)
  // A genuine state the development API signed for someone else: a link they could send to this person.
  const theirs = await signedState(development.key, { ...claims, sub: await apiUserId("project", "stack-user-2") })
  expect(await integrationStateSignedBy(theirs, development.jwks, expect_, now)).toBe(false)
  expect(await integrationStateSignedBy(good, development.jwks, { ...expect_, user: "" }, now)).toBe(false)
  const { sub: _sub, ...noSubject } = claims
  expect(await integrationStateSignedBy(await signedState(development.key, noSubject), development.jwks, expect_, now)).toBe(false)
  // Signed by another key, another issuer, another audience, expired, altered after signing, or not ES256.
  expect(await integrationStateSignedBy(await signedState(other.key, claims), development.jwks, expect_, now)).toBe(false)
  expect(await integrationStateSignedBy(await signedState(development.key, { ...claims, iss: "https://cmux-api/staging" }), development.jwks, expect_, now)).toBe(false)
  expect(await integrationStateSignedBy(await signedState(development.key, { ...claims, aud: "api" }), development.jwks, expect_, now)).toBe(false)
  expect(await integrationStateSignedBy(good, development.jwks, expect_, now + 601_000)).toBe(false)
  const { exp: _exp, ...noExpiry } = claims
  expect(await integrationStateSignedBy(await signedState(development.key, noExpiry), development.jwks, expect_, now)).toBe(false)
  const [h, , sig] = good.split(".")
  expect(await integrationStateSignedBy(`${h}.${b64url(JSON.stringify({ ...claims, team: "team_ffffffffffffffffffff" }))}.${sig}`, development.jwks, expect_, now)).toBe(false)
  expect(await integrationStateSignedBy(await signedState(development.key, claims, { alg: "none" }), development.jwks, expect_, now)).toBe(false)
  // No keys (the development API did not answer), or an answer in another shape.
  for (const jwks of [undefined, null, {}, { keys: "x" }, { keys: [null, { kty: "RSA" }] }]) {
    expect(await integrationStateSignedBy(good, jwks, expect_, now)).toBe(false)
  }
  for (const state of [undefined, "", "not-a-jwt", "a.b.c", 42 as unknown as string]) {
    expect(await integrationStateSignedBy(state, development.jwks, expect_, now)).toBe(false)
  }
  expect(integrationEnvironmentHint(42 as unknown as string)).toBeUndefined()
})

test("the console reads its own session's person and whether the token still has time", () => {
  const now = Date.UTC(2026, 10, 18)
  expect(accessTokenSubject(token({ sub: "stack-user-1", exp: now / 1000 + 300 }), now)).toEqual({ subject: "stack-user-1", fresh: true })
  // Expired, about to expire, or no expiry: the console refreshes before it sends anything.
  expect(accessTokenSubject(token({ sub: "stack-user-1", exp: now / 1000 - 1 }), now)).toEqual({ subject: "stack-user-1", fresh: false })
  expect(accessTokenSubject(token({ sub: "stack-user-1", exp: now / 1000 + 10 }), now)?.fresh).toBe(false)
  expect(accessTokenSubject(token({ sub: "stack-user-1" }), now)?.fresh).toBe(false)
  for (const t of [undefined, "", "not-a-jwt", token({ exp: now / 1000 + 300 }), token({ sub: "" }), token({ sub: 7 })]) expect(accessTokenSubject(t, now)).toBeUndefined()
})

test("a 401 from the development API is not a signed-out console", () => {
  expect(developmentRefusal(401)?.code).toBe("auth.development_refused")
  expect(developmentRefusal(200)).toBeUndefined()
  expect(developmentRefusal(403)).toBeUndefined()
})

test("an app's connect goes back to the app with a plain 302, not the router's redirect (#46018)", () => {
  const state = token({ ret: "cmux-dev-gh-connect-46018://integration/complete", team: "team_0123456789abcdef0123" })
  const answer = integrationAppHandoffResponse(`https://console.cmux.dev/integrations/callback?state=${state}&code=abc&installation_id=42&setup_action=install`)
  expect(answer?.status).toBe(302)
  const location = new URL(answer!.headers.get("Location")!)
  expect(location.protocol).toBe("cmux-dev-gh-connect-46018:")
  expect(`${location.host}${location.pathname}`).toBe("integration/complete")
  expect(Object.fromEntries(location.searchParams)).toEqual({ state, code: "abc", installation_id: "42", setup_action: "install" })
  expect(answer!.headers.get("Cache-Control")).toBe("no-store")
  expect(answer!.headers.get("Referrer-Policy")).toBe("no-referrer")
  // A cancel on GitHub still goes back, so the app stops waiting.
  const cancel = integrationAppHandoffResponse(`https://console.cmux.dev/integrations/callback?state=${state}&error=access_denied`)
  expect(new URL(cancel!.headers.get("Location")!).searchParams.get("error")).toBe("access_denied")
})

test("any other callback renders the page", () => {
  const base = "https://console.cmux.dev/integrations/callback"
  expect(integrationAppHandoffResponse(`${base}?state=${token({ team: "team_0123456789abcdef0123" })}&code=abc`)).toBeUndefined()
  expect(integrationAppHandoffResponse(`${base}?state=${token({ ret: "cmux://workspace/ws_" + "0".repeat(32) })}&code=abc`)).toBeUndefined()
  expect(integrationAppHandoffResponse(`${base}?state=${token({ ret: "https://evil.example/integration/complete" })}&code=abc`)).toBeUndefined()
  expect(integrationAppHandoffResponse(`${base}?code=abc`)).toBeUndefined()
  // Only `<an app scheme>://integration/complete` itself is an app handoff: nothing after it, no other scheme.
  for (const ret of [
    "cmux://integration/complete/x",
    "cmux://integration/completeX",
    "cmux://integration/complete?next=https://evil.example",
    "CMUX://integration/complete",
    "cmuxx://integration/complete",
    "javascript://integration/complete",
    `cmux-dev-${"a".repeat(41)}://integration/complete`,
  ])
    expect(integrationAppHandoffResponse(`${base}?state=${token({ ret })}&code=abc`)).toBeUndefined()
})

test("the link carries only what GitHub sends: an installation id that is not a number is dropped", () => {
  const state = token({ ret: "cmux://integration/complete" })
  const answer = integrationAppHandoffResponse(`https://console.cmux.dev/integrations/callback?state=${state}&code=abc&installation_id=42%0d%0aX-Injected:1&extra=1`)
  expect(Object.fromEntries(new URL(answer!.headers.get("Location")!).searchParams)).toEqual({ state, code: "abc" })
})

test("the route itself answers the provider's redirect: the 302 for an app's connect, the page for any other (#46018)", async () => {
  // The production 500 was the route's wiring, not the helper: this holds the GET handler on the route.
  const { Route } = await import("../src/routes/integrations/callback")
  const get = (Route.options.server as { handlers: { GET: (ctx: { request: Request; next: () => unknown }) => unknown } }).handlers.GET
  const base = "https://console.cmux.dev/integrations/callback"
  const page = new Response("page")
  let rendered = 0
  const next = () => {
    rendered += 1
    return page
  }
  const handoff = (await get({ request: new Request(`${base}?state=${token({ ret: "cmux-nightly://integration/complete" })}&code=abc`), next })) as Response
  expect(handoff.status).toBe(302)
  expect(handoff.headers.get("Location")!.startsWith("cmux-nightly://integration/complete?state=")).toBe(true)
  expect(rendered).toBe(0)
  expect(await get({ request: new Request(`${base}?state=${token({ team: "team_0123456789abcdef0123" })}&code=abc`), next })).toBe(page)
  expect(rendered).toBe(1)
})

const PRODUCTION_API = "https://cloud-api.cmux.dev"
const at = (api = PRODUCTION_API, host?: string) => ({ api: () => api, ...(host ? { host } : {}) })

test("GitHub's redirect from an installation that already existed (no code) goes on to the API's authorize route", () => {
  const base = "https://console.cmux.dev/integrations/callback"
  // What GitHub sends after Save on an existing installation: the id and `update`, never a code.
  for (const ret of ["cmux://integration/complete", undefined]) {
    const state = token({ provider: "github", team: "team_0123456789abcdef0123", ...(ret ? { ret } : {}) })
    const answer = integrationAuthorizeBounce(`${base}?installation_id=167&setup_action=update&state=${state}`, at())
    expect(answer?.status).toBe(302)
    const location = new URL(answer!.headers.get("Location")!)
    expect(`${location.origin}${location.pathname}`).toBe(`${PRODUCTION_API}${GITHUB_AUTHORIZE_PATH}`)
    // Only the state and the installation go on: `setup_action` and anything else stay behind.
    expect(Object.fromEntries(location.searchParams)).toEqual({ state, installation_id: "167" })
    expect(answer!.headers.get("Cache-Control")).toBe("no-store")
    expect(answer!.headers.get("Referrer-Policy")).toBe("no-referrer")
  }
})

test("a development state on the staging console goes to the development API's authorize route, and nowhere else does", () => {
  const dev = token({ provider: "github", iss: "https://cmux-api/development" })
  const query = `installation_id=9&setup_action=update&state=${dev}`
  const onStaging = integrationAuthorizeBounce(`https://${STAGING_CONSOLE_HOST}/integrations/callback?${query}`, at(STAGING_API_URL, STAGING_CONSOLE_HOST))
  expect(onStaging!.headers.get("Location")!.startsWith(`${DEVELOPMENT_API_URL}${GITHUB_AUTHORIZE_PATH}?`)).toBe(true)
  const onProduction = integrationAuthorizeBounce(`https://console.cmux.dev/integrations/callback?${query}`, at(PRODUCTION_API, "console.cmux.dev"))
  expect(onProduction!.headers.get("Location")!.startsWith(`${PRODUCTION_API}${GITHUB_AUTHORIZE_PATH}?`)).toBe(true)
})

test("every other callback is left alone: a code, a cancel, an install request, another provider, no installation", () => {
  const base = "https://console.cmux.dev/integrations/callback"
  const state = token({ provider: "github", ret: "cmux://integration/complete" })
  let asked = 0
  const never = { api: () => { asked += 1; return PRODUCTION_API } }
  for (const query of [
    // A fresh install, or the return from GitHub's authorize page: the code is here, so it is finished as before.
    `state=${state}&code=abc&installation_id=167&setup_action=install`,
    `state=${state}&code=abc`,
    `state=${state}&error=access_denied&installation_id=167`,
    // An organization member's request: nothing is installed yet, so there is nothing to authorize.
    `state=${state}&installation_id=167&setup_action=request`,
    `state=${state}&setup_action=update`,
    `state=${state}&installation_id=abc&setup_action=update`,
    `installation_id=167&setup_action=update`,
    `state=not-a-jwt&installation_id=167&setup_action=update`,
    `state=${token({ provider: "linear" })}&installation_id=167`,
    `state=${token({ ret: "cmux://integration/complete" })}&installation_id=167&setup_action=update`,
  ])
    expect(integrationAuthorizeBounce(`${base}?${query}`, never)).toBeUndefined()
  // The API's address is read only for a redirect, so a console that cannot name its API still serves every other callback.
  expect(asked).toBe(0)
})

test("the route sends a code-less GitHub redirect on before the app hand-off, and hands the app the one that has a code", async () => {
  const { Route } = await import("../src/routes/integrations/callback")
  const get = (Route.options.server as { handlers: { GET: (ctx: { request: Request; next: () => unknown }) => unknown } }).handlers.GET
  const base = "https://console.cmux.dev/integrations/callback"
  const state = token({ provider: "github", ret: "cmux://integration/complete" })
  const page = new Response("page")
  let rendered = 0
  const next = () => {
    rendered += 1
    return page
  }
  const before = process.env.CMUX_API_URL
  process.env.CMUX_API_URL = PRODUCTION_API
  try {
    // Sent straight to the app, this redirect could only be refused: it has no code.
    const bounced = (await get({ request: new Request(`${base}?installation_id=167&setup_action=update&state=${state}`), next })) as Response
    expect(bounced.status).toBe(302)
    expect(bounced.headers.get("Location")).toBe(`${PRODUCTION_API}${GITHUB_AUTHORIZE_PATH}?${new URLSearchParams({ state, installation_id: "167" })}`)
    // GitHub's authorize page then comes back with a code and the API's new state: that one is the app's to finish.
    const handed = (await get({ request: new Request(`${base}?code=abc&state=${state}`), next })) as Response
    expect(handed.headers.get("Location")!.startsWith("cmux://integration/complete?state=")).toBe(true)
    expect(rendered).toBe(0)
    // The API would not sign the state again: the page says so (the app reads any error as a cancel and shows
    // nothing), and nothing is sent round a second time.
    expect(await get({ request: new Request(`${base}?state=${state}&error=${AUTHORIZE_REFUSED}`), next })).toBe(page)
    expect(rendered).toBe(1)
    // A cancel on GitHub's authorize page is still the app's to hear.
    const cancelled = (await get({ request: new Request(`${base}?state=${state}&error=access_denied`), next })) as Response
    expect(new URL(cancelled.headers.get("Location")!).searchParams.get("error")).toBe("access_denied")
  } finally {
    if (before === undefined) delete process.env.CMUX_API_URL
    else process.env.CMUX_API_URL = before
  }
})
