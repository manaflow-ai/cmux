import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { DEVELOPMENT_API_URL, DEVELOPMENT_STATE_ISSUER, developmentRefusal, integrationCompletionApi, integrationEnvironmentHint, integrationStateSignedBy, STAGING_API_URL, STAGING_CONSOLE_HOST } from "../src/lib/integration-callback"

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

test("a development state is forwarded only when the development API's key signed it", async () => {
  const development = await keyPair()
  const other = await keyPair()
  const now = Date.UTC(2026, 10, 18)
  const claims = { iss: DEVELOPMENT_STATE_ISSUER, aud: "cmux-integration-state", sub: "user", team: "team_0123456789abcdef0123", exp: now / 1000 + 600 }
  const good = await signedState(development.key, claims)
  expect(await integrationStateSignedBy(good, development.jwks, DEVELOPMENT_STATE_ISSUER, now)).toBe(true)
  // The issuer hint alone (what a hand-made link can carry) is not enough.
  expect(integrationEnvironmentHint(token({ iss: DEVELOPMENT_STATE_ISSUER }))).toBe("development")
  expect(await integrationStateSignedBy(token({ ...claims }), development.jwks, DEVELOPMENT_STATE_ISSUER, now)).toBe(false)
  // Signed by another key, another issuer, another audience, expired, altered after signing, or not ES256.
  expect(await integrationStateSignedBy(await signedState(other.key, claims), development.jwks, DEVELOPMENT_STATE_ISSUER, now)).toBe(false)
  expect(await integrationStateSignedBy(await signedState(development.key, { ...claims, iss: "https://cmux-api/staging" }), development.jwks, DEVELOPMENT_STATE_ISSUER, now)).toBe(false)
  expect(await integrationStateSignedBy(await signedState(development.key, { ...claims, aud: "api" }), development.jwks, DEVELOPMENT_STATE_ISSUER, now)).toBe(false)
  expect(await integrationStateSignedBy(good, development.jwks, DEVELOPMENT_STATE_ISSUER, now + 601_000)).toBe(false)
  const { exp: _exp, ...noExpiry } = claims
  expect(await integrationStateSignedBy(await signedState(development.key, noExpiry), development.jwks, DEVELOPMENT_STATE_ISSUER, now)).toBe(false)
  const [h, , sig] = good.split(".")
  expect(await integrationStateSignedBy(`${h}.${b64url(JSON.stringify({ ...claims, team: "team_ffffffffffffffffffff" }))}.${sig}`, development.jwks, DEVELOPMENT_STATE_ISSUER, now)).toBe(false)
  expect(await integrationStateSignedBy(await signedState(development.key, claims, { alg: "none" }), development.jwks, DEVELOPMENT_STATE_ISSUER, now)).toBe(false)
  // No keys (the development API did not answer), or an answer in another shape.
  for (const jwks of [undefined, null, {}, { keys: "x" }, { keys: [null, { kty: "RSA" }] }]) {
    expect(await integrationStateSignedBy(good, jwks, DEVELOPMENT_STATE_ISSUER, now)).toBe(false)
  }
  for (const state of [undefined, "", "not-a-jwt", "a.b.c", 42 as unknown as string]) {
    expect(await integrationStateSignedBy(state, development.jwks, DEVELOPMENT_STATE_ISSUER, now)).toBe(false)
  }
  expect(integrationEnvironmentHint(42 as unknown as string)).toBeUndefined()
})

test("a 401 from the development API is not a signed-out console", () => {
  expect(developmentRefusal(401, false)?.code).toBe("auth.development_refused")
  // The console could not refresh its own session: that is signed out.
  expect(developmentRefusal(401, true)).toBeUndefined()
  expect(developmentRefusal(200, false)).toBeUndefined()
  expect(developmentRefusal(403, false)).toBeUndefined()
})
