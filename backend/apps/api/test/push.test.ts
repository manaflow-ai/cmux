import { env, exports } from "cloudflare:workers"
import { idFactory, type Principal } from "@cmux/ownership"
import type { FeedItem, PushTarget } from "@cmux/protocol"
import { exportPKCS8, generateKeyPair, importJWK, jwtVerify, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { userDomain, type UserState } from "../src/domains/user.ts"
import { apnsPayload, apnsRequest, classifyApns, payloadText, providerToken, sendApns } from "../src/push/apns.ts"

const phone: Principal = { identity: "inst_ios00000000000000000", kind: "install", user: "user_aaaaaaaaaaaaaaaaaaaa", install: "inst_ios00000000000000000" }
const ipad: Principal = { ...phone, identity: "inst_pad00000000000000000", install: "inst_pad00000000000000000" }
const session: Principal = { identity: "session:user_aaaaaaaaaaaaaaaaaaaa", kind: "session", user: "user_aaaaaaaaaaaaaaaaaaaa" }
const system: Principal = { identity: "system:user", kind: "system" }
const tok = (c: string) => c.repeat(64)

let n = 0
const reduce = (s: UserState, p: Principal, op: string, params: unknown) => {
  const tx = `t${n++}`
  return userDomain.reduce(s, op, params, { principal: p, now: 1_000 + n, tx, newId: idFactory(tx) })
}

describe("push targets (UserDO)", () => {
  const inst = (kind: string, revoked_at: number | null = null, id = "") => ({ id, kind, revoked_at }) as unknown as UserState["installs"][string]
  const seed = (): UserState => ({
    ...userDomain.initial(),
    installs: { [phone.install!]: inst("ios", null, phone.install), [ipad.install!]: inst("ios", null, ipad.install), inst_cli00000000000000000: inst("cli", null, "inst_cli00000000000000000") }
  })
  const reg = (s: UserState, p: Principal, token: string, topic = "dev.cmux.ios") =>
    reduce(s, p, "push.target.register", { token, topic, environment: "production", device_name: "iPhone" })

  it("refuses non-iOS installs, sessions and topics outside the cmux apps", () => {
    const cli: Principal = { ...phone, identity: "inst_cli00000000000000000", install: "inst_cli00000000000000000" }
    expect(reg(seed(), cli, tok("c"))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(reg(seed(), session, tok("c"))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(reg(seed(), phone, tok("c"), "com.example.other")).toMatchObject({ ok: false, code: "validation.invalid" })
  })

  it("hands a token to a new install on the same phone once the old install is revoked, and revoke drops its targets", () => {
    let s = seed()
    const r1 = reg(s, phone, tok("d"))
    if (r1.ok) s = r1.state
    const revoked = reduce(s, session, "install.revoke", { install: phone.install })
    expect(revoked.ok).toBe(true)
    const after = (revoked as { state: UserState }).state
    expect(after.push_targets).toEqual({})
    // An object from before revoke dropped targets: the revoked install still holds the token; a new install takes it.
    const stale: UserState = { ...after, push_targets: s.push_targets }
    expect(reg(stale, ipad, tok("d"))).toMatchObject({ ok: true, value: { install: ipad.install } })
    const taken = reg(after, ipad, tok("d"))
    expect(taken).toMatchObject({ ok: true, value: { install: ipad.install } })
  })

})

const item = (over: Partial<FeedItem> = {}): FeedItem =>
  ({
    id: "fi_aaaaaaaaaaaaaaaaaaaa", home: "cloud", type: "request", kind: "approve", title: "Run npm run build?", body: "", priority: "high",
    dedupe_key: null, thread: "claude-code:s1", context: {}, attachments: [], actions: [], open: null,
    poster: { kind: "harness", scope: "inst:x", label: "api", harness: "Claude Code" }, state: "open", answer: null, cancel: null, needs_mac: false,
    expires_at: 10_000_000_000_000, read_at: null, seen_at: null, archived_at: null, snoozed_until: null, push_due_at: null, pushed_at: null,
    count: 1, order: 1, revision: 1, created_at: 1, updated_at: 1, closed_at: null, ...over
  }) as FeedItem
const target = (environment: "production" | "development" = "production"): PushTarget => ({ token: tok("d"), topic: "dev.cmux.ios", environment, install: "inst_ios00000000000000000", device_name: "iPhone", registered_at: 1 })

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const call = async (path: string, token: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json()) as any }
}
const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

describe("push targets end to end (workerd)", () => {
  it("an iPhone install registers its token; FeedDO's read sees it; a drop removes it", async () => {
    const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
    const session = await new SignJWT({ email: "push@example.com", name: "push" }).setProtectedHeader({ alg: "ES256", kid: "stack-test" })
      .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`).setAudience(testEnv.STACK_PROJECT_ID).setSubject("push-user").setIssuedAt().setExpirationTime("10m").sign(key)
    const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
    const user = (await op(session, "user.ensure", {})).json.value.id as string
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const install = (await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "ios", name: "iPhone", device_name: "iPhone", platform: "ios" })).json.value.id as string
    const ch = await call("/v1/auth/challenge", undefined, { user, install })
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    const token = (await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })).json.access_token as string
    const reg = await op(token, "push.target.register", { token: tok("f"), topic: "dev.cmux.ios", environment: "production", device_name: "iPhone" })
    expect(reg.json).toMatchObject({ ok: true, value: { install, token: tok("f") } })
    const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)) as unknown as { pushTargets(u: string): Promise<Array<PushTarget>>; dropPushTarget(u: string, t: string, r: string): Promise<void> }
    expect((await stub.pushTargets(user)).map((t) => t.token)).toEqual([tok("f")])
    await stub.dropPushTarget(user, tok("f"), "Unregistered")
    expect(await stub.pushTargets(user)).toEqual([])
  })
})
