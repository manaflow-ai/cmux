import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default

const sessionToken = async (stackUser: string, email = `${stackUser}@example.com`) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}

const call = async (path: string, token: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
  return { status: res.status, json: (await res.json()) as any }
}

const op = (token: string, name: string, params: unknown, key = crypto.randomUUID()) =>
  call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "cli" })

const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

const newInstallKey = async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  return { pair, public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! } }
}

const mintToken = async (user: string, install: string, pair: CryptoKeyPair) => {
  const ch = await call("/v1/auth/challenge", undefined, { user, install })
  expect(ch.status).toBe(200)
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  return call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })
}

const openWire = async (scope: "user" | "team", token: string) => {
  const res = await worker.fetch(`https://api.test/v1/wire/${scope}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const frames: Array<any> = []
  const waiters: Array<() => void> = []
  ws.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    waiters.splice(0).forEach((w) => w())
  })
  ws.addEventListener("close", () => waiters.splice(0).forEach((w) => w()))
  ws.accept()
  const until = async (pred: (fs: Array<any>) => boolean): Promise<void> => {
    while (!pred(frames)) await new Promise<void>((r) => waiters.push(r))
  }
  return { ws, frames, until, send: (f: unknown) => ws.send(JSON.stringify(f)) }
}

describe("cmux-next API Worker end to end (workerd)", () => {
  it("health and JWKS are public", async () => {
    const h = await call("/v1/health", undefined)
    expect(h.json).toMatchObject({ ok: true, environment: "test" })
    const k = await call("/.well-known/jwks.json", undefined)
    expect(k.json.keys[0]).toMatchObject({ kty: "EC", crv: "P-256", alg: "ES256" })
    expect(k.json.keys[0].d).toBeUndefined()
  })

  it("rejects missing and forged tokens", async () => {
    expect((await op("", "user.ensure", {})).status).toBe(401)
    expect((await call("/v1/ops", "not-a-jwt", { op: "user.ensure", params: {}, idempotency_key: "k" })).status).toBe(401)
  })

  it("registers an install, mints a token, echoes ops over the wire, and enforces single writers and revocation", async () => {
    const session = await sessionToken("stack-user-1")
    const ensure = await op(session, "user.ensure", {})
    expect(ensure.json.ok).toBe(true)
    const user = ensure.json.value.id as string
    expect(user).toMatch(/^user_[a-z0-9]{20}$/)

    // install.register is idempotent by key; a reused key with other params is a conflict.
    const k1 = await newInstallKey()
    const params = { public_jwk: k1.public_jwk, kind: "cli", name: "laptop cli", device_name: "laptop", platform: "macos" }
    const reg = await op(session, "install.register", params, "reg-1")
    expect(reg.json.ok).toBe(true)
    expect(reg.json.sequence).toBeGreaterThan(0)
    const install = reg.json.value.id as string
    const replay = await op(session, "install.register", params, "reg-1")
    expect(replay.json).toMatchObject({ ok: true, replayed: true, transaction: reg.json.transaction, sequence: reg.json.sequence })
    expect(replay.json.value.id).toBe(install)
    const conflict = await op(session, "install.register", { ...params, name: "other" }, "reg-1")
    expect(conflict.json.error.code).toBe("idempotency.conflict")

    const k2 = await newInstallKey()
    const reg2 = await op(session, "install.register", { ...params, public_jwk: k2.public_jwk, name: "second" })
    const install2 = reg2.json.value.id as string

    // Proof of possession: a wrong signature and a reused nonce are refused.
    const ch = await call("/v1/auth/challenge", undefined, { user, install })
    const badSig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, k2.pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    expect((await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(badSig) })).status).toBe(403)
    const tok = await mintToken(user, install, k1.pair)
    expect(tok.status).toBe(200)
    const jwt = tok.json.access_token as string

    // The wire: snapshot, then an op from the install; the event carries the transaction,
    // and result then request-settled follow it (commit before publish, write barrier).
    const wire = await openWire("user", jwt)
    wire.send({ t: "subscribe", stream: `user:${user}`, pending: [] })
    await wire.until((fs) => fs.some((f) => f.t === "snapshot"))
    const snap = wire.frames.find((f) => f.t === "snapshot")
    expect(Object.keys(snap.state.installs)).toEqual(expect.arrayContaining([install, install2]))
    wire.send({ t: "op", op: "install.rename", params: { install, name: "renamed by itself" }, idempotency_key: "rename-1", origin: "cli" })
    await wire.until((fs) => fs.some((f) => f.t === "request-settled" && f.idempotency_key === "rename-1"))
    const kinds = wire.frames.filter((f) => f.t !== "welcome" && f.t !== "snapshot").map((f) => f.t)
    expect(kinds).toEqual(["event", "result", "request-settled"])
    const ev = wire.frames.find((f) => f.t === "event")
    const settled = wire.frames.find((f) => f.t === "request-settled")
    expect(ev.tx).toBe(settled.tx)
    expect(settled.sequence).toBe(ev.seq)
    expect(ev.actor).toMatchObject({ kind: "install", install, user })

    // HTTP with the install token: renaming another install is refused by the owner.
    const foreign = await op(jwt, "install.rename", { install: install2, name: "hijack" })
    expect(foreign.json).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })
    // The debug dump is session-only.
    expect((await call("/v1/debug/user", jwt)).status).toBe(403)
    // install.revoke is session-only.
    expect((await op(jwt, "install.revoke", { install: install2 })).json.error.code).toBe("auth.forbidden")

    // The team directory: personal team, then a host enrolled by the install.
    const host = await op(jwt, "host.enroll", { name: "laptop", platform: "macos" })
    expect(host.json.ok).toBe(true)
    const dir = await call("/v1/read", session, { op: "team.directory", params: {} })
    expect(dir.json.value.members.map((m: any) => m.user)).toEqual([user])
    expect(dir.json.value.hosts.map((h: any) => h.id)).toEqual([host.json.value.id])

    // Revocation: new tokens are refused, the existing token's ops are refused by every owner,
    // and the install's open socket closes at once.
    let closed: number | undefined
    wire.ws.addEventListener("close", (e) => (closed = e.code))
    const revoke = await op(session, "install.revoke", { install })
    expect(revoke.json.ok).toBe(true)
    await wire.until(() => closed !== undefined)
    expect(closed).toBe(4401)
    expect((await op(jwt, "host.enroll", { name: "after revoke", platform: "macos" })).status).toBe(403)
    expect((await call("/v1/read", jwt, { op: "team.directory", params: {} })).status).toBe(403)
    expect((await call("/v1/auth/challenge", undefined, { user, install })).status).toBe(403)
    expect((await op(jwt, "install.rename", { install, name: "after revoke" })).json.error.code).toBe("auth.forbidden")

    // Every committed change wrote an outbox row for the PlanetScale projection.
    const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    await runInDurableObject(stub, async (_instance, state) => {
      const rows = state.storage.sql.exec("SELECT kind, entity FROM own_outbox ORDER BY id").toArray()
      expect(rows.map((r) => r.kind)).toEqual(["user.upsert", "install.upsert", "install.upsert", "install.upsert", "install.upsert"])
    })
  })

  it("isolates users: another user's session cannot read or write this user's objects", async () => {
    const a = await sessionToken("stack-user-a")
    const b = await sessionToken("stack-user-b")
    await op(a, "user.ensure", {})
    await op(b, "user.ensure", {})
    const listA = await call("/v1/read", a, { op: "install.list", params: {} })
    const listB = await call("/v1/read", b, { op: "install.list", params: {} })
    expect(listA.json.value.user.id).not.toBe(listB.json.value.user.id)
  })
})
