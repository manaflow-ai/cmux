import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { accessTokenSubject, apiUserId, DEVELOPMENT_API_URL, DEVELOPMENT_STATE_ISSUER, developmentRefusal, integrationAppAttemptHint, integrationAppHandoffLink, integrationCompletionApi, integrationEnvironmentHint, integrationStateSignedBy, STAGING_API_URL, STAGING_CONSOLE_HOST, verifiedIntegrationState } from "../src/lib/integration-callback"

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

const HASH = "h".repeat(43)
const HANDOFF = "k".repeat(43)
const CONN = "conn_0123456789abcdefghij"

test("an app-started connect is recognised only by its completion link and attempt hash", () => {
  expect(integrationAppAttemptHint(token({ ret: "cmux://integration/complete", anh: HASH }))).toBe(true)
  // No hash (an older connect), a chat link, another scheme or path: not the app's attempt.
  for (const claims of [{ ret: "cmux://integration/complete" }, { ret: "cmux://session/ses-01", anh: HASH }, { ret: "https://evil.example/integration/complete", anh: HASH }, { ret: "cmux://integration/complete?x=1", anh: HASH }, {}])
    expect(integrationAppAttemptHint(token(claims))).toBe(false)
  expect(integrationAppAttemptHint(undefined)).toBe(false)
  expect(integrationAppAttemptHint("not-a-jwt")).toBe(false)
})

test("the callback verifies a state from any API environment by its keys, and refuses an unverified one", async () => {
  const api = await keyPair()
  const other = await keyPair()
  const now = Date.UTC(2026, 10, 18)
  const claims = { iss: "https://cmux-api/production", aud: "cmux-integration-state", sub: "user_1", conn: CONN, ret: "cmux://integration/complete", anh: HASH, exp: now / 1000 + 600 }
  const good = await signedState(api.key, claims)
  expect(await verifiedIntegrationState(good, api.jwks, {}, now)).toMatchObject({ conn: CONN })
  // An unsigned or hand-made state (what anyone can put in a link), another key, expired, another audience or issuer form.
  expect(await verifiedIntegrationState(token(claims), api.jwks, {}, now)).toBeUndefined()
  expect(await verifiedIntegrationState(await signedState(other.key, claims), api.jwks, {}, now)).toBeUndefined()
  expect(await verifiedIntegrationState(good, api.jwks, {}, now + 601_000)).toBeUndefined()
  expect(await verifiedIntegrationState(await signedState(api.key, { ...claims, aud: "api" }), api.jwks, {}, now)).toBeUndefined()
  expect(await verifiedIntegrationState(await signedState(api.key, { ...claims, iss: "https://evil.example/production" }), api.jwks, {}, now)).toBeUndefined()
  expect(await verifiedIntegrationState(good, undefined, {}, now)).toBeUndefined()
})

test("the app link carries only the connection and the handoff value, never the provider's code", () => {
  const claims = { iss: "https://cmux-api/staging", conn: CONN, ret: "cmux-dev-x://integration/complete", anh: HASH }
  const value = { connection: CONN, return_to: claims.ret, handoff: HANDOFF }
  const link = integrationAppHandoffLink(claims, value)
  expect(link).toBe(`cmux-dev-x://integration/complete?connection=${CONN}&handoff=${HANDOFF}`)
  const query = new URL(link!).searchParams
  for (const key of ["code", "state", "installation_id", "setup_action"]) expect(query.has(key)).toBe(false)
  // An answer for another connection or link, a malformed handoff value, extra fields: no link, or none of them in it.
  expect(integrationAppHandoffLink(claims, { ...value, connection: "conn_ffffffffffffffffffff" })).toBeUndefined()
  expect(integrationAppHandoffLink(claims, { ...value, return_to: "cmux://integration/complete" })).toBeUndefined()
  expect(integrationAppHandoffLink(claims, { ...value, handoff: "short" })).toBeUndefined()
  expect(integrationAppHandoffLink(claims, { ...value, code: "secret" })).not.toContain("secret")
  expect(integrationAppHandoffLink(undefined, value)).toBeUndefined()
  expect(integrationAppHandoffLink({ ...claims, anh: undefined }, value)).toBeUndefined()
  // A production state never opens a development build's link.
  expect(integrationAppHandoffLink({ ...claims, iss: "https://cmux-api/production" }, value)).toBeUndefined()
  expect(integrationAppHandoffLink({ ...claims, iss: "https://cmux-api/production", ret: "cmux://integration/complete" }, { ...value, return_to: "cmux://integration/complete" })).toBe(`cmux://integration/complete?connection=${CONN}&handoff=${HANDOFF}`)
})
