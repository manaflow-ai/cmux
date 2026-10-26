import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK, decodeJwt } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * (e) Chief token principals: an install of the owner mints a token for one of the owner's
 * chiefs. principal.user is the owner, principal.agent the chief; every request asks the owner's
 * UserDO, so archiving the chief refuses the next request at once.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace }
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
const call = async (path: string, token: string | undefined, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })
const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

const installFor = async (sub: string) => {
  const session = await sessionToken(sub)
  const user = (await op(session, "user.ensure", {})).json.value.id as string
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const install = (await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" })).json.value.id as string
  const mint = async (agent?: string) => {
    const ch = await call("/v1/auth/challenge", undefined, { user, install })
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    return call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig), ...(agent ? { agent } : {}) })
  }
  return { session, user, install, mint }
}

describe("chief tokens", { timeout: 60_000 }, () => {
  it("carry the owner and the chief, and stop at once when the chief is archived", async () => {
    const a = await installFor("chief-tok-a")
    await op(a.session, "chief.create", {})
    const chief = (await op(a.session, "chief.create", { display_name: "Helper" })).json.value
    const tok = await a.mint(chief.id)
    expect(tok.status).toBe(200)
    expect(decodeJwt(tok.json.access_token)).toMatchObject({ sub: a.user, inst: a.install, agt: chief.id })
    // A request through another owner (FeedDO) is admitted as that chief.
    const posted = await op(tok.json.access_token, "feed.post", { type: "notice", kind: "notice", title: "from the chief" })
    expect(posted.json.ok, JSON.stringify(posted.json)).toBe(true)
    expect(posted.json.value.item.poster).toMatchObject({ agent: chief.id })
    // A chief token cannot change the owner's account.
    expect((await op(tok.json.access_token, "install.revoke", { install: a.install })).json.ok).toBe(false)
    // Archive the chief: the same token is refused on the next request, and its open sockets close.
    const muxRes = await worker.fetch(`https://api.test/v1/wire/mux/${chief.id}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${tok.json.access_token}` } })
    expect(muxRes.status).toBe(101)
    const ws = muxRes.webSocket!
    let closed: number | undefined
    ws.addEventListener("close", (e) => (closed = e.code))
    ws.accept()
    await new Promise((r) => setTimeout(r, 100))
    const archived = await op(a.session, "chief.archive", { chief: chief.id, expected_rev: chief.rev })
    expect(archived.json.ok, JSON.stringify(archived.json)).toBe(true)
    const after = await op(tok.json.access_token, "feed.post", { type: "notice", kind: "notice", title: "after archive" })
    expect(after.status).toBe(403)
    for (let i = 0; i < 100 && closed === undefined; i++) await new Promise((r) => setTimeout(r, 10))
    expect(closed).toBe(4401)
    // A token for an archived chief, or another user's chief, is never minted.
    expect((await a.mint(chief.id)).status).toBe(403)
    const b = await installFor("chief-tok-b")
    const other = (await op(b.session, "chief.create", {})).json.value
    expect((await a.mint(other.id)).status).toBe(403)
  })

  it("stop at once when the chief is deleted", async () => {
    const a = await installFor("chief-tok-del")
    await op(a.session, "chief.create", {})
    const chief = (await op(a.session, "chief.create", { display_name: "Doomed" })).json.value
    const tok = await a.mint(chief.id)
    expect(tok.status).toBe(200)
    const muxRes = await worker.fetch(`https://api.test/v1/wire/mux/${chief.id}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${tok.json.access_token}` } })
    expect(muxRes.status).toBe(101)
    const ws = muxRes.webSocket!
    let closed: number | undefined
    ws.addEventListener("close", (e) => (closed = e.code))
    ws.accept()
    await new Promise((r) => setTimeout(r, 100))
    const deleted = await op(a.session, "chief.delete", { chief: chief.id, expected_rev: chief.rev })
    expect(deleted.json.ok, JSON.stringify(deleted.json)).toBe(true)
    expect((await op(tok.json.access_token, "feed.post", { type: "notice", kind: "notice", title: "after delete" })).status).toBe(403)
    for (let i = 0; i < 100 && closed === undefined; i++) await new Promise((r) => setTimeout(r, 10))
    expect(closed).toBe(4401)
    expect((await a.mint(chief.id)).status).toBe(403)
  })

  it("cannot read or subscribe the owner's inbox; the owner session still can (cx-59n8.11)", async () => {
    const a = await installFor("chief-tok-inbox")
    const chief = (await op(a.session, "chief.create", { display_name: "Helper" })).json.value
    const tok = (await a.mint(chief.id)).json.access_token as string
    // HTTP read: inbox.list is the owner's DM list with message previews.
    const ownerList = await call("/v1/read", a.session, { op: "inbox.list", params: {} })
    expect(ownerList.status, JSON.stringify(ownerList.json)).toBe(200)
    const chiefList = await call("/v1/read", tok, { op: "inbox.list", params: {} })
    expect(chiefList.status, JSON.stringify(chiefList.json)).toBe(403)
    expect(JSON.stringify(chiefList.json)).toContain("auth.forbidden")
    // The cloud socket (the stream behind the daemon's cloud-inbox-subscribe).
    const subscribe = async (token: string) => {
      const res = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${token}` } })
      expect(res.status).toBe(101)
      const ws = res.webSocket!
      const frames: Array<any> = []
      let wake: (() => void) | undefined
      ws.addEventListener("message", (e) => {
        frames.push(JSON.parse(e.data as string))
        wake?.()
      })
      ws.accept()
      ws.send(JSON.stringify({ t: "subscribe", stream: `inbox:${a.user}`, pending: [] }))
      const answer = () => frames.find((f) => (f.t === "snapshot" && f.stream === `inbox:${a.user}`) || f.t === "error")
      for (let i = 0; i < 200 && !answer(); i++) await Promise.race([new Promise<void>((r) => (wake = r)), new Promise((r) => setTimeout(r, 25))])
      ws.close()
      return answer()
    }
    expect(await subscribe(a.session)).toMatchObject({ t: "snapshot", stream: `inbox:${a.user}` })
    expect(await subscribe(tok)).toMatchObject({ t: "error", code: "auth.forbidden" })
  })

  it("keep their own conversation and wake queue after the inbox refusal (cx-59n8.11, hq-84)", async () => {
    const a = await installFor("chief-tok-own")
    const chief = (await op(a.session, "chief.create", { display_name: "Helper" })).json.value
    const conversation = chief.main_conversation as string
    // The chief's MuxDO binding and main conversation land on UserDO's alarm.
    const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(a.user))
    for (let i = 0; i < 20 && (await call("/v1/read", a.session, { op: "conversation.history", params: { conversation, limit: 1 } })).status !== 200; i++) await fireAlarm(userDO)
    const sent = await call("/v1/ops", a.session, { op: "message.send", params: { conversation, client_msg_id: "to-chief", parts: [{ type: "text", text: "hello chief" }] }, idempotency_key: "to-chief", origin: "user" })
    expect(sent.json.ok, JSON.stringify(sent.json)).toBe(true)
    const tok = (await a.mint(chief.id)).json.access_token as string
    // Its own conversation: HTTP read (history and thread) and the conversation socket.
    const hist = await call("/v1/read", tok, { op: "conversation.history", params: { conversation, limit: 5 } })
    expect(hist.status, JSON.stringify(hist.json)).toBe(200)
    expect((hist.json.value.messages as Array<{ client_msg_id: string; seq: number }>).some((m) => m.client_msg_id === "to-chief")).toBe(true)
    const seq = (hist.json.value.messages as Array<{ client_msg_id: string; seq: number }>).find((m) => m.client_msg_id === "to-chief")!.seq
    const firstFrame = async (path: string) => {
      const res = await worker.fetch(`https://api.test${path}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${tok}` } })
      expect(res.status).toBe(101)
      const ws = res.webSocket!
      const frames: Array<any> = []
      let wake: (() => void) | undefined
      ws.addEventListener("message", (e) => {
        frames.push(JSON.parse(e.data as string))
        wake?.()
      })
      ws.accept()
      ws.send(JSON.stringify({ t: "subscribe", pending: [] }))
      const answer = () => frames.find((f) => f.t === "snapshot" || f.t === "error")
      for (let i = 0; i < 200 && !answer(); i++) await Promise.race([new Promise<void>((r) => (wake = r)), new Promise((r) => setTimeout(r, 25))])
      ws.close()
      return answer()
    }
    expect(await firstFrame(`/v1/wire/conv/${conversation}`)).toMatchObject({ t: "snapshot" })
    // Its wake queue socket.
    expect(await firstFrame(`/v1/wire/mux/${chief.id}`)).toMatchObject({ t: "snapshot" })
    expect(seq).toBeGreaterThan(0)
    // The brain acks its wakes with this token (optchat-chief brain/mux_ack.rs -> daemon cloud-mux-ack -> mux.ack, no origin).
    // The MuxDO binding lands on UserDO's alarm; until then a refusal is expected, so retry with a fresh key (cx-59n8.17).
    const ack = () => call("/v1/ops", tok, { op: "mux.ack", params: { agent: chief.id, conversation, seq }, idempotency_key: crypto.randomUUID() })
    let acked = await ack()
    for (let i = 0; i < 20 && !acked.json.ok; i++) {
      await fireAlarm(userDO)
      acked = await ack()
    }
    expect(acked.json.ok, JSON.stringify(acked.json)).toBe(true)
    // Another user's install token that names this chief is never minted (auth); a token for another chief is refused here.
    const b = await installFor("chief-tok-own-other")
    const otherChief = (await op(b.session, "chief.create", { display_name: "Other" })).json.value
    const otherTok = (await b.mint(otherChief.id)).json.access_token as string
    const foreign = await call("/v1/ops", otherTok, { op: "mux.ack", params: { agent: chief.id, conversation, seq }, idempotency_key: crypto.randomUUID() })
    expect(foreign.json.ok, JSON.stringify(foreign.json)).toBe(false)
  })
})
