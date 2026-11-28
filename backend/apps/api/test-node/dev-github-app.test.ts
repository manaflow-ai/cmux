import { generateKeyPairSync } from "node:crypto"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { exportJWK, generateKeyPair, importPKCS8 } from "jose"
import { describe, expect, it } from "vitest"
import { GITHUB_TOKEN_PERMISSIONS } from "@cmux/protocol"
import { GITHUB_PUSH_EVENTS } from "../src/integrations/github-push.ts"
import { userIdFor } from "../src/domains/user.ts"
import { signState } from "../src/integrations/state.ts"
import type { Env } from "../src/env.ts"
import { apiUserId, DEVELOPMENT_STATE_ISSUER, integrationStateSignedBy } from "../../dashboard/src/lib/integration-callback.ts"
import { CALLBACK_ORIGIN, createPage, DEVELOPMENT_API_ORIGIN, isLocalHost, LOCAL_PORT, manifest, secretsFromConversion } from "../scripts/dev-github-app.ts"

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
const development = (JSON.parse(stripComments(readFileSync(join(__dirname, "../wrangler.jsonc"), "utf8"))) as { env: { development: { vars: Record<string, string> } } }).env.development.vars

describe("the cmux-cloud-dev App manifest", () => {
  const m = manifest()

  it("returns installs to the console the development Worker names, and webhooks to the development Worker", () => {
    expect(CALLBACK_ORIGIN).toBe(development.INTEGRATIONS_CALLBACK_ORIGIN)
    expect(m.callback_urls).toEqual([`${development.INTEGRATIONS_CALLBACK_ORIGIN}/integrations/callback`])
    expect(DEVELOPMENT_API_ORIGIN).toBe(development.CLOUD_API_ORIGIN)
    expect(m.hook_attributes.url).toBe(`${development.CLOUD_API_ORIGIN}/v1/hooks/github`)
  })

  it("asks for the user's code on install (providers.ts github.complete needs it)", () => {
    expect(m.request_oauth_on_install).toBe(true)
  })

  it("grants every permission the token route mints, at the level the clients ask", () => {
    for (const name of GITHUB_TOKEN_PERMISSIONS) expect(m.default_permissions).toHaveProperty(name)
    for (const name of ["contents", "pull_requests", "issues", "workflows"] as const) expect(m.default_permissions[name]).toBe("write")
    // requireOrgAdmin reads the linking person's org membership.
    expect(m.default_permissions.members).toBe("read")
  })

  it("subscribes to every event the live pull request updates use", () => {
    for (const event of GITHUB_PUSH_EVENTS) expect(m.default_events).toContain(event)
  })

  it("embeds the manifest in the create page escaped", () => {
    const page = createPage("abc")
    expect(page).toContain('action="https://github.com/organizations/manaflow-ai/settings/apps/new?state=abc"')
    expect(page).not.toContain('"name":')
    expect(page).toContain("&quot;name&quot;:&quot;cmux-cloud-dev&quot;")
  })

  it("answers only requests addressed to its own local address", () => {
    expect(isLocalHost(`127.0.0.1:${LOCAL_PORT}`)).toBe(true)
    for (const host of [undefined, "", "127.0.0.1", `localhost:${LOCAL_PORT}`, `rebind.example:${LOCAL_PORT}`, "127.0.0.1:80"]) expect(isLocalHost(host)).toBe(false)
  })
})

describe("secretsFromConversion", () => {
  const pkcs1 = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey.export({ type: "pkcs1", format: "pem" }).toString()
  const answer = { slug: "cmux-cloud-dev", client_id: "Iv23test", client_secret: "test-client-secret", pem: pkcs1, webhook_secret: "test-hook-secret" }

  it("maps GitHub's answer to the Worker secret names with a PKCS#8 key appKey can import", async () => {
    const s = secretsFromConversion(answer)
    expect(Object.keys(s).sort()).toEqual(["GITHUB_APP_CLIENT_ID", "GITHUB_APP_CLIENT_SECRET", "GITHUB_APP_PRIVATE_KEY", "GITHUB_APP_SLUG", "GITHUB_WEBHOOK_SECRET"])
    expect(pkcs1.startsWith("-----BEGIN RSA PRIVATE KEY-----")).toBe(true)
    expect(s.GITHUB_APP_PRIVATE_KEY!.startsWith("-----BEGIN PRIVATE KEY-----")).toBe(true)
    await expect(importPKCS8(s.GITHUB_APP_PRIVATE_KEY!, "RS256")).resolves.toBeDefined()
  })

  it("refuses an answer missing a credential", () => {
    expect(() => secretsFromConversion({ ...answer, client_secret: "" })).toThrow(/client_secret/)
    const { webhook_secret: _w, ...noHook } = answer
    expect(secretsFromConversion(noHook)).not.toHaveProperty("GITHUB_WEBHOOK_SECRET")
  })
})

/**
 * The staging console sends its session to the development API only for a state that API signed for the same
 * person (dashboard src/lib/integration-callback.ts integrationStateSignedBy). That check must accept exactly
 * what signState mints, so this signs a real state and verifies it the way the console does.
 */
describe("the console's check of a development state", () => {
  it("derives the same user id as the API", async () => {
    expect(await apiUserId("project-1", "stack-user-1")).toBe(userIdFor("project-1", "stack-user-1"))
  })

  it("accepts a state signState minted for this person, and no one else's", async () => {
    const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true })
    const env = { JWT_PRIVATE_JWK: JSON.stringify(await exportJWK(privateKey)), ENVIRONMENT: "development" } as Env
    // The published form (src/auth.ts publicJwks): the public half, alg and use.
    const jwks = { keys: [{ ...(await exportJWK(publicKey)), alg: "ES256", use: "sig" }] }
    const me = userIdFor("project-1", "stack-user-1")
    const state = await signState(env, { conn: "conn_1", team: "team_0123456789abcdef0123", user: me, provider: "github", return_to: "cmux-dev-tag://integration/complete" })
    expect(await integrationStateSignedBy(state, jwks, { issuer: DEVELOPMENT_STATE_ISSUER, user: me })).toBe(true)
    expect(await integrationStateSignedBy(state, jwks, { issuer: DEVELOPMENT_STATE_ISSUER, user: userIdFor("project-1", "stack-user-2") })).toBe(false)
    const staging = await signState({ ...env, ENVIRONMENT: "staging" } as Env, { conn: "conn_1", team: "team_0123456789abcdef0123", user: me, provider: "github" })
    expect(await integrationStateSignedBy(staging, jwks, { issuer: DEVELOPMENT_STATE_ISSUER, user: me })).toBe(false)
  })
})
