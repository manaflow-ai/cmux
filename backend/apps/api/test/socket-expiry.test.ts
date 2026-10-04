import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject as runIn } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"

/**
 * P0 (coordinator 2026-10-03): a listen-only socket must stop receiving events once its token
 * expires (at the next event, and by an alarm sweep with no events) and once its install is
 * revoked, on every owner class, not only UserDO.
 */
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any) => Promise<T>) => Promise<T>
const testEnv = env as unknown as Record<string, any> & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
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
const op = async (t: string, name: string, params: unknown) =>
  (await (await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify({ op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" }) })).json()) as any
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

/** Opens a subscribed socket on an owner object with an explicit principal. */
const listen = async (stub: any, entity: string, principal: Record<string, unknown>) => {
  const res = await stub.fetch("https://do/", { headers: { Upgrade: "websocket", "x-cmux-entity": entity, "x-cmux-principal": JSON.stringify(principal) } })
  expect(res.status).toBe(101)
  const ws = res.webSocket as WebSocket
  const frames: Array<any> = []
  const state = { closed: undefined as number | undefined }
  ws.addEventListener("message", (e) => frames.push(JSON.parse(e.data as string)))
  ws.addEventListener("close", (e) => (state.closed = e.code))
  ws.accept()
  ws.send(JSON.stringify({ t: "subscribe", pending: [] }))
  for (let i = 0; i < 50 && !frames.some((f) => f.t === "snapshot"); i++) await sleep(10)
  return { frames, state, events: () => frames.filter((f) => f.t === "event").length }
}

interface Case {
  readonly name: string
  readonly setup: () => Promise<{ stub: any; entity: string; principal: Record<string, unknown>; poke: (n: number) => Promise<void> }>
}

const userOf = async (sub: string) => {
  const t = await sessionToken(sub)
  const ensured = await op(t, "user.ensure", {})
  const user = userIdFor(testEnv.STACK_PROJECT_ID, sub)
  return { t, user, team: ensured.value.personal_team as string }
}

const cases: ReadonlyArray<Case> = [
  {
    name: "TeamDO",
    setup: async () => {
      const u = await userOf(`sock-team-${crypto.randomUUID().slice(0, 6)}`)
      const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(u.team))
      const principal = { identity: `session:${u.user}`, kind: "session", user: u.user, team: u.team }
      return {
        stub,
        entity: u.team,
        principal,
        poke: async (n) => {
          const version = (await stub.readOp(u.team, principal, "team.policy.get", {})).value.policy.version
          await stub.submit(u.team, principal, { t: "op", op: "team.policy.update", params: { changes: [{ key: "updates.minimumVersion", value: { value: `0.0.${n}`, mode: "enforced" } }], expected_version: version, reason: "t" }, idempotency_key: `p${n}`, origin: "user" })
        }
      }
    }
  },
  {
    name: "FeedDO",
    setup: async () => {
      const u = await userOf(`sock-feed-${crypto.randomUUID().slice(0, 6)}`)
      const stub = testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(u.user))
      const principal = { identity: `session:${u.user}`, kind: "session", user: u.user }
      return {
        stub,
        entity: u.user,
        principal,
        poke: async (n) => {
          await stub.submit(u.user, principal, { t: "op", op: "feed.prefs.set", params: { push_enabled: n % 2 === 0 }, idempotency_key: `f${n}`, origin: "user" })
        }
      }
    }
  },
  {
    name: "ConversationDO",
    setup: async () => {
      const u = await userOf(`sock-conv-${crypto.randomUUID().slice(0, 6)}`)
      const id = `conv_${"0123456789ABCDEFGHJKMNPQRS".split("").sort(() => Math.random() - 0.5).join("")}`
      const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
      const principal = { identity: `session:${u.user}`, kind: "session", user: u.user, display_name: "A" }
      await stub.submit(id, principal, { t: "op", op: "conversation.create", params: { id, kind: "group", title: "T", participants: [{ id: u.user, kind: "human", display_name: "A" }] }, idempotency_key: "c", origin: "user" })
      return {
        stub,
        entity: id,
        principal,
        poke: async (n) => {
          await stub.submit(id, principal, { t: "op", op: "message.send", params: { client_msg_id: `m${n}`, parts: [{ type: "text", text: `m${n}` }] }, idempotency_key: `m${n}`, origin: "user" })
        }
      }
    }
  }
]

describe("listen-only sockets end with their token (P0)", { timeout: 60_000 }, () => {
  for (const c of cases) {
    it(`${c.name}: an expired token gets no further event and the socket closes 4401`, async () => {
      const s = await c.setup()
      const expires = Date.now() + 1000
      const sock = await listen(s.stub, s.entity, { ...s.principal, expires_at: expires })
      await s.poke(1)
      for (let i = 0; i < 50 && sock.events() === 0; i++) await sleep(10)
      expect(sock.events()).toBeGreaterThan(0)
      // Follow-up events of the first op (TeamDO commits system ops after it) may arrive until the expiry.
      await sleep(Math.max(0, expires - Date.now()) + 5)
      const before = sock.events()
      await sleep(100)
      await s.poke(2)
      await sleep(100)
      expect(sock.events()).toBe(before)
      expect(sock.state.closed).toBe(4401)
    })

    it(`${c.name}: an expired token's socket closes with no event (alarm sweep)`, async () => {
      const s = await c.setup()
      const sock = await listen(s.stub, s.entity, { ...s.principal, expires_at: Date.now() + 300 })
      await sleep(400)
      await runDurableObjectAlarm(s.stub)
      await sleep(50)
      expect(sock.state.closed).toBe(4401)
    })
  }

  it("a revoked install's socket on another owner (FeedDO) gets no further event", async () => {
    const sub = `sock-rev-${crypto.randomUUID().slice(0, 6)}`
    const u = await userOf(sub)
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const reg = await op(u.t, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" })
    const install = reg.value.id as string
    const userStub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(u.user))
    const grant = await runInDurableObject(userStub, async (i) => i.boundEngine.currentState.installs[install].grant as string)
    const feed = testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(u.user))
    const principal = { identity: install, kind: "install", user: u.user, install, grant, install_kind: "mac", grant_classes: ["read", "mutate-own"], expires_at: Date.now() + 600_000 }
    const sock = await listen(feed, u.user, principal)
    const session = { identity: `session:${u.user}`, kind: "session", user: u.user }
    const poke = (n: number) => feed.submit(u.user, session, { t: "op", op: "feed.prefs.set", params: { push_enabled: n % 2 === 0 }, idempotency_key: `r${n}`, origin: "user" })
    await poke(1)
    for (let i = 0; i < 50 && sock.events() === 0; i++) await sleep(10)
    expect(sock.events()).toBeGreaterThan(0)
    const before = sock.events()
    expect((await op(u.t, "install.revoke", { install })).ok).toBe(true)
    await runInDurableObject(feed, async (i) => i.forgetInstallChecks?.())
    await poke(2)
    for (let i = 0; i < 50 && sock.state.closed === undefined; i++) await sleep(10)
    expect(sock.events()).toBe(before)
    expect(sock.state.closed).toBe(4401)
  })
})
