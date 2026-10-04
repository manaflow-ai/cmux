import { env, exports } from "cloudflare:workers"
import { createHash } from "node:crypto"
import { invites } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"

/**
 * Home attachments (home-messaging.md section 2): upload intent, bytes to R2 by content hash
 * (verified by the Worker), signed downloads for current participants, and message.send
 * accepting only hashes uploaded for that conversation.
 */
const testEnv = env as unknown as Env & { STACK_TEST_PRIVATE_JWK: string; HOME_ATTACHMENTS: R2Bucket }
const worker = (exports as unknown as { default: Fetcher }).default
type Stub = { submit(e: string, p: Principal, f: unknown): Promise<{ frames: Array<{ t: string; code?: string }> }> }
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const stub = (ns: any, name: string): Stub => ns.get(ns.idFromName(name))

const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

const post = async (path: string, token: string | undefined, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body)
  })
  return { status: res.status, json: (await res.json().catch(() => null)) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => post("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })

interface Who {
  token: string
  user: string
  principal: Principal
}
const signIn = async (sub: string): Promise<Who> => {
  const token = await sessionToken(sub)
  expect((await op(token, "user.ensure", {})).json.ok).toBe(true)
  const user = userIdFor(testEnv.STACK_PROJECT_ID, sub)
  return { token, user, principal: { kind: "session", identity: `session:${user}`, user, team: personalTeamIdFor(user), display_name: sub, email: `${sub}@example.com`, email_verified: true } }
}

let n = 0
/** Valid Crockford ids (the Worker's conversation id rule). */
const convId = () => `conv_01J00000000000000000ATT${String(n++).padStart(3, "0")}`
const result = (r: { frames: Array<{ t: string; code?: string }> }) => r.frames.find((f) => f.t === "result" || f.t === "reject")

/** A group of `owner` (+ `members`, joined through an approved invite) with the given history setting. */
const group = async (owner: Who, members: Array<Who> = [], historyVisible: "all" | "since_join" = "all") => {
  const id = convId()
  const conv = stub(testEnv.CONVERSATION_DO, id)
  const ok = async (who: Principal, o: string, params: unknown, key: string) => expect(result(await conv.submit(id, who, { t: "op", op: o, params, idempotency_key: key }))).toMatchObject({ t: "result" })
  await ok(owner.principal, "conversation.create", { id, kind: "group", title: "Files", participants: [{ id: owner.user, kind: "human", display_name: "Owner" }] }, "c")
  if (historyVisible === "since_join") await ok(owner.principal, "conversation.settings.set", { history_visible: "since_join" }, "s")
  const g = { id, conv, ok, join: (m: Who, i: number) => join(id, ok, owner, m, i) }
  for (const [i, m] of members.entries()) await g.join(m, i)
  return g
}
const join = async (id: string, ok: (w: Principal, o: string, p: unknown, k: string) => Promise<void>, owner: Who, m: Who, i: number) => {
  const proof = invites.hashInviteSecret(`secret-${id}-${i}`)
  const invite = `inv_${String(i).padStart(26, "0")}`
  await ok(owner.principal, "invite.create", { invite_id: invite, address: `addr_${String(i).padStart(26, "0")}`, channel: "sms", display_name: "M", token_hash: invites.hashInviteSecret(proof), locale: "en", copy_variant: "A" }, `i${i}`)
  await ok(m.principal, "invite.accept", { proof }, `a${i}`)
  await ok(owner.principal, "invite.approve_join", { invite_id: invite }, `ap${i}`)
}

const bytesOf = (s: string) => new TextEncoder().encode(s)
const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex")
const intent = (who: Who, conversation: string, body: Uint8Array, over: Record<string, unknown> = {}) =>
  post("/v1/home/attachments/intent", who.token, { conversation, sha256: sha(body), byte_count: body.byteLength, mime_type: "image/png", name: "pic.png", width: 2, height: 2, ...over })
const put = (url: string, body: Uint8Array) => worker.fetch(url, { method: "PUT", body, headers: { "content-length": String(body.byteLength) } })
/** Intent + upload; returns the hash. */
const upload = async (who: Who, conversation: string, body: Uint8Array, over: Record<string, unknown> = {}) => {
  const r = await intent(who, conversation, body, over)
  expect(r.json.ok).toBe(true)
  if (r.json.value.state === "upload") expect((await put(r.json.value.upload_url, body)).status).toBe(200)
  return sha(body)
}
const urlFor = (who: Who, conversation: string, hash: string) => post("/v1/home/attachments/url", who.token, { conversation, hash })
const attachmentPart = (hash: string, body: Uint8Array, over: Record<string, unknown> = {}) => ({ type: "attachment", hash, name: "pic.png", mime_type: "image/png", byte_count: body.byteLength, width: 2, height: 2, ...over })

describe("Home attachments: upload intent", { timeout: 60_000 }, () => {
  it("a participant gets an upload slot; a stranger is refused before any quota or token", async () => {
    const alice = await signIn("att-intent-alice")
    const eve = await signIn("att-intent-eve")
    const { id } = await group(alice)
    const body = bytesOf("png bytes 1")
    const r = await intent(alice, id, body)
    expect(r.status).toBe(200)
    expect(r.json.value).toMatchObject({ state: "upload", method: "PUT" })
    expect(r.json.value.upload_url).toMatch(/^https:\/\/api\.test\/v1\/home\/attachments\/upload\//)
    expect(r.json.value.expires_at).toBeGreaterThan(Date.now())
    const stranger = await intent(eve, id, body)
    expect(stranger.status).toBe(403)
    expect(stranger.json.error.code).toBe("auth.forbidden")
    expect((await intent({ ...eve, token: "" }, id, body)).status).toBe(401)
  })

  it("refuses types off the allow list, executables by extension, and sizes over the cap", async () => {
    const alice = await signIn("att-type-alice")
    const { id } = await group(alice)
    const body = bytesOf("<svg/>")
    expect((await intent(alice, id, body, { mime_type: "image/svg+xml", name: "x.svg" })).status).toBe(415)
    expect((await intent(alice, id, body, { mime_type: "application/zip", name: "setup.exe" })).status).toBe(415)
    const big = await intent(alice, id, body, { byte_count: 25_000_001 })
    expect(big.status).toBe(413)
    expect(big.json.error.code).toBe("attachment.too_large")
  })

  it("takes the daily byte quota per user; a repeated intent for the same hash counts once", async () => {
    const alice = await signIn("att-quota-alice")
    const { id } = await group(alice)
    const video = (i: number) => ({ sha256: sha(bytesOf(`v${i}`)), byte_count: 100_000_000, mime_type: "video/mp4", name: `v${i}.mp4`, duration_ms: 1000 })
    for (let i = 0; i < 10; i++) expect((await post("/v1/home/attachments/intent", alice.token, { conversation: id, ...video(i) })).status).toBe(200)
    // Same (conversation, hash): no new charge.
    expect((await post("/v1/home/attachments/intent", alice.token, { conversation: id, ...video(0) })).status).toBe(200)
    const over = await post("/v1/home/attachments/intent", alice.token, { conversation: id, ...video(10) })
    expect(over.status).toBe(429)
    expect(over.json.error.code).toBe("attachment.quota")
    expect(over.json.error.retry_after_ms).toBeGreaterThan(0)
  })
})

describe("Home attachments: upload and dedupe", { timeout: 60_000 }, () => {
  it("bytes whose SHA-256 differs from the declared hash are refused and not kept", async () => {
    const alice = await signIn("att-hash-alice")
    const { id } = await group(alice)
    const declared = bytesOf("the real bytes")
    const r = await intent(alice, id, declared)
    const forged = bytesOf("other bytes!!!")
    expect(forged.byteLength).toBe(declared.byteLength)
    const bad = await put(r.json.value.upload_url, forged)
    expect(bad.status).toBe(400)
    expect(((await bad.json()) as any).error.code).toBe("attachment.hash_mismatch")
    expect((await testEnv.HOME_ATTACHMENTS.list({ prefix: `home/v1/${id}/` })).objects).toHaveLength(0)
    // The hash is not referenceable after a failed upload.
    const sent = await op(alice.token, "message.send", { conversation: id, client_msg_id: "m1", parts: [attachmentPart(sha(declared), declared)] }, "m1")
    expect(sent.json.error.code).toBe("unknown_attachment")
    // The right bytes go through; a size mismatch is refused too.
    expect((await put(r.json.value.upload_url, bytesOf("short"))).status).toBe(400)
    const good = await put(r.json.value.upload_url, declared)
    expect(good.status).toBe(200)
    expect(((await good.json()) as any).value.state).toBe("stored")
    expect((await put("https://api.test/v1/home/attachments/upload/not-a-token", declared)).status).toBe(403)
  })

  it("dedupe answers 'exists' only inside the same conversation and only for hashes the caller can see", async () => {
    const alice = await signIn("att-dedupe-alice")
    const bob = await signIn("att-dedupe-bob")
    const a = await group(alice, [bob])
    const b = await group(alice)
    const body = bytesOf("shared image")
    await upload(alice, a.id, body)
    expect((await intent(alice, a.id, body)).json.value.state).toBe("exists")
    // Another conversation never learns that the hash exists.
    expect((await intent(alice, b.id, body)).json.value.state).toBe("upload")
    expect((await urlFor(alice, b.id, sha(body))).status).toBe(404)
    // Bob is in conversation A but did not upload it and it is not in any message yet.
    expect((await intent(bob, a.id, body)).json.value.state).toBe("upload")
    expect((await urlFor(bob, a.id, sha(body))).status).toBe(404)
    // Once a message references it, Bob sees it.
    expect((await op(alice.token, "message.send", { conversation: a.id, client_msg_id: "m1", parts: [attachmentPart(sha(body), body)] }, "m1")).json.ok).toBe(true)
    expect((await intent(bob, a.id, body)).json.value.state).toBe("exists")
  })
})

describe("Home attachments: message.send and downloads", { timeout: 60_000 }, () => {
  it("message.send refuses an unknown hash and a hash uploaded for another conversation", async () => {
    const alice = await signIn("att-send-alice")
    const a = await group(alice)
    const b = await group(alice)
    const body = bytesOf("foreign bytes")
    const hash = await upload(alice, a.id, body)
    const unknown = await op(alice.token, "message.send", { conversation: a.id, client_msg_id: "u1", parts: [attachmentPart("f".repeat(64), body)] }, "u1")
    expect(unknown.json.error.code).toBe("unknown_attachment")
    const foreign = await op(alice.token, "message.send", { conversation: b.id, client_msg_id: "f1", parts: [attachmentPart(hash, body)] }, "f1")
    expect(foreign.json.error.code).toBe("unknown_attachment")
    expect((await op(alice.token, "message.send", { conversation: a.id, client_msg_id: "ok1", parts: [attachmentPart(hash, body)] }, "ok1")).json.ok).toBe(true)
  })

  it("signed URLs serve the bytes with safe headers to current participants only, and expire", async () => {
    const alice = await signIn("att-get-alice")
    const bob = await signIn("att-get-bob")
    const eve = await signIn("att-get-eve")
    const g = await group(alice, [bob])
    const img = bytesOf("image-bytes-123")
    const pdf = bytesOf("%PDF-1.4 fake")
    const imgHash = await upload(alice, g.id, img)
    const pdfHash = await upload(alice, g.id, pdf, { mime_type: "application/pdf", name: "report.pdf", width: undefined, height: undefined })
    expect((await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [attachmentPart(imgHash, img), attachmentPart(pdfHash, pdf, { mime_type: "application/pdf", name: "report.pdf", width: undefined, height: undefined })] }, "m1")).json.ok).toBe(true)

    const minted = await urlFor(bob, g.id, imgHash)
    expect(minted.status).toBe(200)
    const res = await worker.fetch(minted.json.value.url)
    expect(res.status).toBe(200)
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(img)
    expect(res.headers.get("content-type")).toBe("image/png")
    expect(res.headers.get("content-disposition")).toMatch(/^inline/)
    expect(res.headers.get("x-content-type-options")).toBe("nosniff")
    expect(res.headers.get("content-security-policy")).toContain("sandbox")
    const ranged = await worker.fetch(minted.json.value.url, { headers: { range: "bytes=0-4" } })
    expect(ranged.status).toBe(206)
    expect(await ranged.text()).toBe("image")

    const pdfUrl = (await urlFor(bob, g.id, pdfHash)).json.value.url
    const pdfRes = await worker.fetch(pdfUrl)
    expect(pdfRes.headers.get("content-disposition")).toMatch(/^attachment/)
    await pdfRes.arrayBuffer()

    // A stranger cannot mint; a tampered or expired URL is refused.
    expect((await urlFor(eve, g.id, imgHash)).status).toBe(403)
    const tampered = new URL(minted.json.value.url)
    tampered.searchParams.set("e", String(Date.now() + 3_600_000))
    expect((await worker.fetch(tampered.toString())).status).toBe(403)
    const { downloadPath } = await import("../src/home-attachments.ts")
    const expired = await downloadPath(testEnv, g.id, imgHash, bob.user, Date.now() - 1)
    expect((await worker.fetch(`https://api.test${expired}`)).status).toBe(403)

    // Removing Bob ends his access at once, even with a URL minted before.
    await g.ok(alice.principal, "participants.remove", { participant: bob.user }, "rm")
    expect((await worker.fetch(minted.json.value.url)).status).toBe(403)
  })

  it("history_visible since_join hides attachments of messages before the join", async () => {
    const alice = await signIn("att-floor-alice")
    const bob = await signIn("att-floor-bob")
    const g = await group(alice, [], "since_join")
    const before = bytesOf("before join")
    const hash = await upload(alice, g.id, before)
    expect((await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [attachmentPart(hash, before)] }, "m1")).json.ok).toBe(true)
    await g.join(bob, 0)
    expect((await urlFor(bob, g.id, hash)).status).toBe(404)
    expect((await intent(bob, g.id, before)).json.value.state).toBe("upload")
    const after = bytesOf("after join!")
    const hash2 = await upload(alice, g.id, after)
    expect((await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m2", parts: [attachmentPart(hash2, after)] }, "m2")).json.ok).toBe(true)
    expect((await urlFor(bob, g.id, hash2)).status).toBe(200)
  })
})
