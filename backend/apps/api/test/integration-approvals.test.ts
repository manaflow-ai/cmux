import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import type { Http } from "../src/integrations/providers.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * G8 gateway approvals (integrations-plan.md section 3): a send-external, money or destructive
 * provider op from a non-session principal does not run; the ConnectionDO posts an approve feed
 * request and answers approval.pending. The user's answer runs it once under a derived key.
 */
const testEnv = env as unknown as Record<string, any>
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>

const sessionToken = async (stackUser: string) =>
  new SignJWT({ email: `${stackUser}@example.com`, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const call = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID(), origin = "cli") => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin })
const read = (token: string, name: string, params: unknown = {}) => call("/v1/read", token, { op: name, params })
const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } })

/** A signed-in user with an active Slack connection (fake provider) and a CLI install token (not a person). */
const setup = async (who: string) => {
  const token = await sessionToken(who)
  const ensured = (await op(token, "user.ensure", {})).json.value
  const user = ensured.id as string
  const team = ensured.personal_team as string
  const connect = await op(token, "integration.connect", { provider: "slack", sharing: "team" })
  const conn = connect.json.value.connection.id as string
  const state = new URL(connect.json.value.authorize_url as string).searchParams.get("state")!
  const posts: Array<string> = []
  const http: Http = async (req) => {
    if (req.url.startsWith("https://slack.com/api/oauth.v2.access")) return ok({ ok: true, access_token: "xoxb-g8", scope: "chat:write", team: { id: `T${who}`, name: "Acme" } })
    if (req.url.startsWith("https://slack.com/api/chat.postMessage")) {
      posts.push(await req.text())
      return ok({ ok: true, channel: "C1", ts: "1.2" })
    }
    return new Response("not found", { status: 404 })
  }
  const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
  await inDO(connections, async (instance) => {
    instance.http = http
  })
  expect((await op(token, "integration.complete", { state, code: "c" })).json.ok).toBe(true)
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const install = (await op(token, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: "agent", device_name: "laptop", platform: "macos" })).json.value.id as string
  const post = (path: string, body: unknown) => worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }).then((r) => r.json() as Promise<any>)
  const ch = await post("/v1/auth/challenge", { user, install })
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.message_prefix}${ch.nonce}`)))
  const b64u = btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
  const agent = (await post("/v1/auth/token", { user, install, nonce: ch.nonce, signature: b64u })).access_token as string
  const feed = testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(user))
  const approvals = async () => ((await read(token, "feed.list", {})).json.value.items as Array<any>).filter((i) => i.kind === "approve" && i.poster.kind === "integration")
  const answer = (item: string, decision: "allow" | "deny") => op(token, "feed.answer", { item, answer: decision === "allow" ? { decision, scope: "once" } : { decision } }, crypto.randomUUID(), "user")
  return { token, user, team, conn, agent, posts, connections, feed, approvals, answer }
}

describe("gateway approvals for risky provider ops (G8)", { timeout: 60_000 }, () => {
  it("an agent's send does not run: it answers approval.pending and the user sees op, target and a summary, not the body", async () => {
    const s = await setup("g8-pending")
    const r = await op(s.agent, "slack.post_as_bot", { connection: s.conn, channel: "C1", text: "secret body text" }, "send-1")
    expect(r.json.ok).toBe(false)
    expect(r.json.error.code).toBe("approval.pending")
    const request = r.json.error.details?.request as string
    expect(request).toMatch(/^apr_/)
    expect(s.posts).toHaveLength(0)
    const [item] = await s.approvals()
    expect(item.state).toBe("open")
    expect(JSON.stringify(item.prompt)).toContain("slack.post_as_bot")
    expect(JSON.stringify(item.prompt)).toContain("C1")
    expect(JSON.stringify(item)).not.toContain("secret body text")
    // The approval view fetches the full request with the user's own session; the agent cannot.
    const view = await read(s.token, "integration.approval.get", { request })
    expect(view.json.value).toMatchObject({ request, op: "slack.post_as_bot", state: "pending", params: { text: "secret body text" } })
    expect((await read(s.agent, "integration.approval.get", { request })).json.ok).toBe(false)
    // A retry with the same key stays pending and posts no second request.
    expect((await op(s.agent, "slack.post_as_bot", { connection: s.conn, channel: "C1", text: "secret body text" }, "send-1")).json.error.code).toBe("approval.pending")
    expect(await s.approvals()).toHaveLength(1)
    // The person's own session still runs it directly.
    expect((await op(s.token, "slack.post_as_bot", { connection: s.conn, channel: "C1", text: "mine" })).json.ok).toBe(true)
    expect(s.posts).toHaveLength(1)
  })

  it("the user's approval runs it exactly once, also when the answer is delivered twice; the agent's retry gets the result", async () => {
    const s = await setup("g8-approve")
    const r = await op(s.agent, "slack.post_as_bot", { connection: s.conn, channel: "C1", text: "hello" }, "send-2")
    expect(r.json.error.code).toBe("approval.pending")
    const [item] = await s.approvals()
    expect((await s.answer(item.id, "allow")).json.ok).toBe(true)
    await fireAlarm(s.feed)
    expect(s.posts).toHaveLength(1)
    // A second answer is refused by the feed; a redelivered outbox item replays.
    expect((await s.answer(item.id, "allow")).json.ok).toBe(false)
    await inDO(s.feed, async (i) => i.boundEngine.outbox.replayDead(Date.now(), {}))
    const request = r.json.error.details.request as string
    await inDO(s.connections, async (i) => i.systemDeliver(s.team, `feed:${s.user}`, [{ id: 999_001, op: "integration.approval.answered", key: `again:${request}`, params: { request, decision: "allow", digest: (await read(s.token, "integration.approval.get", { request })).json.value.digest } }]))
    expect(s.posts).toHaveLength(1)
    const done = await op(s.agent, "slack.post_as_bot", { connection: s.conn, channel: "C1", text: "hello" }, "send-2")
    expect(done.json).toMatchObject({ ok: true, value: { channel: "C1", ts: "1.2" } })
  })

  it("an answer whose digest does not match the stored request is refused and never runs", async () => {
    const s = await setup("g8-stale")
    const r = await op(s.agent, "slack.post_as_bot", { connection: s.conn, channel: "C1", text: "hello" }, "send-3")
    const request = r.json.error.details.request as string
    await inDO(s.connections, async (i) => i.systemDeliver(s.team, `feed:${s.user}`, [{ id: 999_002, op: "integration.approval.answered", key: `stale:${request}`, params: { request, decision: "allow", digest: "sha256:" + "0".repeat(64) } }]))
    expect(s.posts).toHaveLength(0)
    // Another user's feed cannot answer for this user.
    await inDO(s.connections, async (i) => i.systemDeliver(s.team, "feed:user_someoneelse0000000", [{ id: 999_003, op: "integration.approval.answered", key: `other:${request}`, params: { request, decision: "allow", digest: (await read(s.token, "integration.approval.get", { request })).json.value.digest } }]))
    expect(s.posts).toHaveLength(0)
    expect((await read(s.token, "integration.approval.get", { request })).json.value.state).toBe("pending")
  })

  it("denial and expiry are final; pending approvals per connection are capped", async () => {
    const s = await setup("g8-deny")
    const r = await op(s.agent, "slack.post_as_bot", { connection: s.conn, channel: "C1", text: "no" }, "send-4")
    const [item] = await s.approvals()
    expect((await s.answer(item.id, "deny")).json.ok).toBe(true)
    await fireAlarm(s.feed)
    expect(s.posts).toHaveLength(0)
    expect((await op(s.agent, "slack.post_as_bot", { connection: s.conn, channel: "C1", text: "no" }, "send-4")).json.error.code).toBe("approval.denied")
    // Expiry: a pending request past its time is final.
    const late = await op(s.agent, "slack.post_as_bot", { connection: s.conn, channel: "C1", text: "late" }, "send-5")
    const lateRequest = late.json.error.details.request as string
    await inDO(s.connections, async (_i, st) => st.storage.sql.exec(`UPDATE integration_approvals SET expires_at = 1 WHERE request = ?`, lateRequest))
    expect((await op(s.agent, "slack.post_as_bot", { connection: s.conn, channel: "C1", text: "late" }, "send-5")).json.error.code).toBe("approval.expired")
    expect(r.json.error.code).toBe("approval.pending")
    // Flood guard: at most MAX pending per connection.
    let last: any
    for (let n = 0; n < 25; n++) last = await op(s.agent, "slack.post_as_bot", { connection: s.conn, channel: "C1", text: `m${n}` })
    expect(last.json.error.code).toBe("approval.too_many_pending")
  })
})
