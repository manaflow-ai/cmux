import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

/**
 * Privacy (coordinator P1): FeedDO events are kept up to 30 days / 10,000 events, longer than
 * an item. Their params must not hold the item's text (title, body, label, prompt), so a pruned
 * item's text is gone from the log. Clients mirror the owner-written items (event extras), never
 * ops, so params carry only the op's kind.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; FEED_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const call = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown) => call("/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

const SECRET_TITLE = "Deploy secret-project-zeta to prod"
const SECRET_COMMAND = "psql postgres://admin:hunter2@db/prod"
const post = { type: "request", kind: "approve", title: SECRET_TITLE, prompt: { action: { type: "command", summary: "Run migration", command: SECRET_COMMAND }, scopes: ["once"] }, poster: { agent: "term_9", harness: "claude-code", label: "Claude Code · zeta" } }

describe("feed event privacy", { timeout: 60_000 }, () => {
  it("stored feed.post events hold no item text", async () => {
    const session = await sessionToken("feed-privacy")
    const user = (await op(session, "user.ensure", {})).json.value.id as string
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const install = (await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" })).json.value.id as string
    const chRes = await worker.fetch("https://api.test/v1/auth/challenge", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user, install }) })
    const ch = (await chRes.json()) as { message_prefix: string; nonce: string }
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.message_prefix}${ch.nonce}`))
    const tokRes = await worker.fetch("https://api.test/v1/auth/token", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user, install, nonce: ch.nonce, signature: b64u(sig) }) })
    const token = ((await tokRes.json()) as { access_token: string }).access_token
    const posted = await op(token, "feed.post", post)
    expect(posted.json.ok).toBe(true)

    const stored = await runInDurableObject(testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(user)), async (_i, state) =>
      state.storage.sql.exec("SELECT op, params FROM own_events").toArray().map((r: any) => `${r.op} ${r.params}`).join("\n")
    )
    expect(stored).toContain("feed.post")
    for (const text of [SECRET_TITLE, SECRET_COMMAND, "Claude Code · zeta", "Run migration"]) expect(stored).not.toContain(text)
  })
})
