import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject as runInDO } from "cloudflare:test"
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
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const runInDurableObject = runInDO as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
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

const text = (t: string) => ({ type: "text", text: t })
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
const urlFor = (who: Who, conversation: string, hash: string, at?: { message_id: string; part_index: number }) => post("/v1/home/attachments/url", who.token, { conversation, hash, ...at })
/** The opaque object id in a minted download URL. */
const objectIdOf = (url: string) => new URL(url).pathname.split("/").pop()!
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
    const big = await intent(alice, id, body, { byte_count: 100_000_001 })
    expect(big.status).toBe(413)
    expect(big.json.error.code).toBe("attachment.too_large")
  })

  it("takes the daily byte quota per user (2 GB); a repeated intent for the same hash adds no bytes", async () => {
    const alice = await signIn("att-quota-alice")
    const { id } = await group(alice)
    const video = (i: number) => ({ sha256: sha(bytesOf(`v${i}`)), byte_count: 100_000_000, mime_type: "video/mp4", name: `v${i}.mp4`, duration_ms: 1000 })
    for (let i = 0; i < 20; i++) expect((await post("/v1/home/attachments/intent", alice.token, { conversation: id, ...video(i) })).status).toBe(200)
    // Same (conversation, hash): no new bytes.
    expect((await post("/v1/home/attachments/intent", alice.token, { conversation: id, ...video(0) })).status).toBe(200)
    const over = await post("/v1/home/attachments/intent", alice.token, { conversation: id, ...video(20) })
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
    // The slot was used once; a size mismatch on a new slot is refused too; then the right bytes go through.
    expect((await put(r.json.value.upload_url, declared)).status).toBe(403)
    expect((await put((await intent(alice, id, declared)).json.value.upload_url, bytesOf("short"))).status).toBe(400)
    const good = await put((await intent(alice, id, declared)).json.value.upload_url, declared)
    expect(good.status).toBe(200)
    expect(((await good.json()) as any).value.state).toBe("stored")
    // Replaying a slot is refused and leaves the recorded object intact.
    expect((await put(r.json.value.upload_url, forged)).status).toBe(403)
    expect((await testEnv.HOME_ATTACHMENTS.list({ prefix: `home/v1/${id}/` })).objects).toHaveLength(1)
    expect((await op(alice.token, "message.send", { conversation: id, client_msg_id: "m2", parts: [attachmentPart(sha(declared), declared)] }, "m2")).json.ok).toBe(true)
    const got = await worker.fetch((await urlFor(alice, id, sha(declared))).json.value.url)
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(declared)
    expect((await put(`https://api.test/v1/home/attachments/upload/${id}/${"0".repeat(32)}.k2.bad`, declared)).status).toBe(403)
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
    const expired = downloadPath(testEnv, { conversation: g.id, objectId: objectIdOf(minted.json.value.url), actor: bob.user, expires: Date.now() - 1 })
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

describe("Home attachments: retention", { timeout: 60_000 }, () => {
  it("collection deletes only unreferenced uploads past the grace period; a retracted message releases its object", async () => {
    const alice = await signIn("att-gc-alice")
    const g = await group(alice)
    const kept = bytesOf("referenced")
    const orphan = bytesOf("never sent")
    const keptHash = await upload(alice, g.id, kept)
    await upload(alice, g.id, orphan)
    const sent = await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [attachmentPart(keptHash, kept)] }, "m1")
    expect(sent.json.ok).toBe(true)
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(g.id)) as unknown as { collectAttachments(e: string, now?: number): Promise<number> }
    const objects = async () => (await testEnv.HOME_ATTACHMENTS.list({ prefix: `home/v1/${g.id}/` })).objects.map((o) => o.key.split("/")[3])
    // Inside the grace period nothing goes.
    expect(await conv.collectAttachments(g.id)).toBe(0)
    const later = Date.now() + 25 * 3_600_000
    expect(await conv.collectAttachments(g.id, later)).toBe(1)
    expect(await objects()).toHaveLength(1)
    // The orphan's hash is no longer referenceable.
    expect((await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m2", parts: [attachmentPart(sha(orphan), orphan)] }, "m2")).json.error.code).toBe("unknown_attachment")
    expect((await op(alice.token, "message.retract", { conversation: g.id, message_id: sent.json.value.message_id }, "r1")).json.ok).toBe(true)
    expect(await conv.collectAttachments(g.id, later)).toBe(1)
    expect(await objects()).toEqual([])
  })
})

describe("Home attachments: review fixes (P2/P3)", { timeout: 120_000 }, () => {
  it("message.send needs the author to be an uploader or see a referencing message; 'not yours' and 'unknown' look the same", async () => {
    const alice = await signIn("att-own-alice")
    const bob = await signIn("att-own-bob")
    const g = await group(alice, [bob])
    const unsent = bytesOf("alice unsent")
    const hash = await upload(alice, g.id, unsent)
    const theirs = await op(bob.token, "message.send", { conversation: g.id, client_msg_id: "b1", parts: [attachmentPart(hash, unsent)] }, "b1")
    const unknown = await op(bob.token, "message.send", { conversation: g.id, client_msg_id: "b2", parts: [attachmentPart("f".repeat(64), unsent)] }, "b2")
    expect(theirs.json.error.code).toBe("unknown_attachment")
    expect(unknown.json.error.code).toBe(theirs.json.error.code)
    // Once Alice sent it, Bob sees it in a message and may forward it.
    expect((await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "a1", parts: [attachmentPart(hash, unsent)] }, "a1")).json.ok).toBe(true)
    expect((await op(bob.token, "message.send", { conversation: g.id, client_msg_id: "b3", parts: [attachmentPart(hash, unsent)] }, "b3")).json.ok).toBe(true)

    // since_join: a hash only referenced before Carol's join is unknown to her.
    const carol = await signIn("att-own-carol")
    const h = await group(alice, [], "since_join")
    const old = bytesOf("pre-join file")
    const oldHash = await upload(alice, h.id, old)
    expect((await op(alice.token, "message.send", { conversation: h.id, client_msg_id: "o1", parts: [attachmentPart(oldHash, old)] }, "o1")).json.ok).toBe(true)
    await h.join(carol, 0)
    expect((await op(carol.token, "message.send", { conversation: h.id, client_msg_id: "c1", parts: [attachmentPart(oldHash, old)] }, "c1")).json.error.code).toBe("unknown_attachment")
  })

  it("the ConversationDO alarm collects unreferenced uploads after 24 h and releases the uploader's storage; conversation deletion removes the prefix", async () => {
    const alice = await signIn("att-alarm-alice")
    const g = await group(alice)
    const kept = bytesOf("kept by a message")
    const orphan = bytesOf("orphan upload")
    const keptHash = await upload(alice, g.id, kept)
    await upload(alice, g.id, orphan)
    const doStub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(g.id))
    // An upload commit schedules the sweep at the oldest upload's grace end.
    const { alarm, sweepAt } = await runInDurableObject(doStub, async (i: any, state) => ({ alarm: await state.storage.getAlarm(), sweepAt: i.nextWakeAt(null, Date.now()) as number }))
    expect(alarm).not.toBeNull()
    expect(sweepAt).toBeGreaterThan(Date.now() + 23 * 3_600_000)
    expect((await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [attachmentPart(keptHash, kept)] }, "m1")).json.ok).toBe(true)
    const userStub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(alice.user))
    const stored = () => runInDurableObject(userStub, async (_i, state) => Number((state.storage.sql.exec("SELECT COALESCE(SUM(bytes), 0) AS b FROM home_attachment_stored").toArray()[0] as { b: number }).b))
    expect(await stored()).toBe(kept.byteLength + orphan.byteLength)
    // Age both records past the grace period and fire the alarm.
    await runInDurableObject(doStub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_objects SET created_at = ?", Date.now() - 25 * 3_600_000))
    await runDurableObjectAlarm(doStub)
    const left = async () => (await testEnv.HOME_ATTACHMENTS.list({ prefix: `home/v1/${g.id}/` })).objects.length
    expect(await left()).toBe(1)
    expect(await stored()).toBe(kept.byteLength)
    expect((await urlFor(alice, g.id, keptHash)).status).toBe(200)
    // Deleting the conversation's storage removes every object under its prefix.
    const conv = doStub as unknown as { deleteAttachmentStorage(e: string): Promise<number> }
    expect(await conv.deleteAttachmentStorage(g.id)).toBe(1)
    expect(await left()).toBe(0)
    expect(await stored()).toBe(0)
  })

  it("an upload slot is single use; slot and download URLs carry no file name and no hash", async () => {
    const alice = await signIn("att-slot-alice")
    const g = await group(alice)
    const body = bytesOf("single use bytes")
    const r = await intent(alice, g.id, body, { name: "Secret Plans 2027.png" })
    const url = r.json.value.upload_url as string
    expect(url).not.toContain("Secret")
    expect(decodeURIComponent(url)).not.toContain("Secret")
    expect(url).not.toContain(sha(body))
    expect(Buffer.from(url.split("/").pop()!.split(".")[0]!, "base64url").toString("latin1")).not.toContain("Secret")
    expect((await put(url, body)).status).toBe(200)
    const again = await put(url, body)
    expect(again.status).toBe(403)
    expect(((await again.json()) as any).error.code).toBe("attachment.slot_invalid")
    expect((await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [attachmentPart(sha(body), body, { name: "Secret Plans 2027.png" })] }, "m1")).json.ok).toBe(true)
    const minted = (await urlFor(alice, g.id, sha(body))).json.value.url as string
    expect(minted).not.toContain(sha(body))
    expect(decodeURIComponent(minted)).not.toContain("Secret")
  })

  it("Range past the end is 416; the file name comes from the message part; text types download as text/plain attachments", async () => {
    const alice = await signIn("att-range-alice")
    const g = await group(alice)
    const md = bytesOf("# notes\n<script>alert(1)</script>\n")
    const hash = await upload(alice, g.id, md, { mime_type: "text/markdown", name: "a.md", width: undefined, height: undefined })
    const sent = await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [text("see"), attachmentPart(hash, md, { mime_type: "text/markdown", name: "Meeting notes.md", width: undefined, height: undefined })] }, "m1")
    expect(sent.json.ok).toBe(true)
    const url = (await urlFor(alice, g.id, hash, { message_id: sent.json.value.message_id, part_index: 1 })).json.value.url as string
    const res = await worker.fetch(url)
    expect(res.headers.get("content-type")).toBe("text/plain; charset=utf-8")
    expect(res.headers.get("content-disposition")).toMatch(/^attachment; filename="Meeting notes\.md"/)
    await res.arrayBuffer()
    const past = await worker.fetch(url, { headers: { range: `bytes=${md.byteLength + 10}-${md.byteLength + 20}` } })
    expect(past.status).toBe(416)
    expect(past.headers.get("content-range")).toBe(`bytes */${md.byteLength}`)
    const clamped = await worker.fetch(url, { headers: { range: `bytes=2-999999` } })
    expect(clamped.status).toBe(206)
    expect(clamped.headers.get("content-range")).toBe(`bytes 2-${md.byteLength - 1}/${md.byteLength}`)
    await clamped.arrayBuffer()
    // A part index that does not hold this hash is refused at mint.
    expect((await urlFor(alice, g.id, hash, { message_id: sent.json.value.message_id, part_index: 0 })).status).toBe(404)
  })

  it("download signatures carry a key id (current and previous accepted) and bind the method", async () => {
    const alice = await signIn("att-kid-alice")
    const g = await group(alice)
    const body = bytesOf("rotating keys")
    const hash = await upload(alice, g.id, body)
    const minted = (await urlFor(alice, g.id, hash)).json.value.url as string
    expect(new URL(minted).searchParams.get("k")).toBe(testEnv.HOME_ATTACHMENT_KEY_ID)
    const { downloadPath } = await import("../src/home-attachments.ts")
    const args = { conversation: g.id, objectId: objectIdOf(minted), actor: alice.user, expires: Date.now() + 60_000 }
    const previous = await worker.fetch(`https://api.test${downloadPath(testEnv, { ...args, kid: testEnv.HOME_ATTACHMENT_KEY_PREVIOUS_ID })}`)
    expect(previous.status).toBe(200)
    await previous.arrayBuffer()
    expect((await worker.fetch(`https://api.test${downloadPath(testEnv, { ...args, kid: "unknown" })}`)).status).toBe(403)
    expect((await worker.fetch(`https://api.test${downloadPath(testEnv, { ...args, method: "PUT" })}`)).status).toBe(403)
    const head = await worker.fetch(minted, { method: "HEAD" })
    expect(head.status).toBe(200)
  })

  it("stored bytes per uploader are capped at 10 GB", async () => {
    const alice = await signIn("att-stored-alice")
    const g = await group(alice)
    const user = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(alice.user)) as unknown as { recordAttachmentStorage(e: string, key: string, bytes: number): Promise<void> }
    await user.recordAttachmentStorage(alice.user, "home/v1/elsewhere/x", 10_000_000_000 - 5)
    const r = await intent(alice, g.id, bytesOf("123456"))
    expect(r.status).toBe(429)
    expect(r.json.error.code).toBe("attachment.storage_quota")
  })
})

describe("Home attachments: presigned R2 PUT for 32-100 MB", { timeout: 120_000 }, () => {
  it("SigV4 presigning matches the AWS documented example", async () => {
    const { presignUrl } = await import("../src/r2-presign.ts")
    const url = presignUrl({
      method: "GET",
      url: "https://examplebucket.s3.amazonaws.com/test.txt",
      region: "us-east-1",
      accessKeyId: "AKIAIOSFODNN7EXAMPLE",
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      headers: {},
      expiresSec: 86400,
      now: Date.UTC(2013, 4, 24)
    })
    expect(new URL(url).searchParams.get("X-Amz-Signature")).toBe("aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
  })

  it("a large file gets a presigned PUT that signs length and checksum; commit HEADs size and checksum before it is referenceable", async () => {
    const alice = await signIn("att-big-alice")
    const g = await group(alice)
    const big = new Uint8Array(40_000_000).fill(7)
    const hash = sha(big)
    const r = await intent(alice, g.id, big, { mime_type: "video/mp4", name: "trip.mp4", duration_ms: 1000, width: undefined, height: undefined })
    expect(r.json.value).toMatchObject({ state: "upload", method: "PUT", mode: "presigned" })
    const url = new URL(r.json.value.upload_url)
    expect(url.origin).toBe(testEnv.HOME_ATTACHMENTS_S3_ENDPOINT)
    expect(url.searchParams.get("X-Amz-SignedHeaders")).toBe("content-length;host;x-amz-checksum-sha256")
    expect(Number(url.searchParams.get("X-Amz-Expires"))).toBe(900)
    expect(r.json.value.headers).toEqual({ "content-length": String(big.byteLength), "x-amz-checksum-sha256": Buffer.from(hash, "hex").toString("base64") })
    expect(r.json.value.upload_url).not.toContain(hash)
    const key = decodeURIComponent(url.pathname).split("/").slice(2).join("/")
    const commit = (slot: string) => post("/v1/home/attachments/commit", alice.token, { conversation: g.id, slot })
    // Committing before the bytes land is refused and keeps the slot.
    expect((await commit(r.json.value.slot)).status).toBe(409)
    // The client's PUT lands (simulated on the bucket binding with R2's checksum).
    await testEnv.HOME_ATTACHMENTS.put(key, big, { sha256: hash })
    const done = await commit(r.json.value.slot)
    expect(done.status).toBe(200)
    expect(done.json.value.state).toBe("stored")
    expect((await commit(r.json.value.slot)).status).toBe(403)
    expect((await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [attachmentPart(hash, big, { mime_type: "video/mp4", name: "trip.mp4", width: undefined, height: undefined })] }, "m1")).json.ok).toBe(true)

    // Other bytes of the same length under a second slot: refused at commit and deleted.
    const other = new Uint8Array(40_000_000).fill(9)
    const r2 = await intent(alice, g.id, other, { mime_type: "video/mp4", name: "b.mp4", width: undefined, height: undefined, sha256: sha(new Uint8Array(40_000_000).fill(8)) })
    const key2 = decodeURIComponent(new URL(r2.json.value.upload_url).pathname).split("/").slice(2).join("/")
    await testEnv.HOME_ATTACHMENTS.put(key2, other, { sha256: sha(other) })
    const bad = await commit(r2.json.value.slot)
    expect(bad.status).toBe(400)
    expect(bad.json.error.code).toBe("attachment.hash_mismatch")
    expect(await testEnv.HOME_ATTACHMENTS.head(key2)).toBeNull()
  })
})
