/** Home attachments: the backend lead's review and re-check fixes, presigned large uploads. Helpers: home-attachments-support.ts. */
import { describe, expect, it } from "vitest"
import { runDurableObjectAlarm } from "cloudflare:test"
import { createHash } from "node:crypto"
import type { Principal } from "@cmux/ownership"
import type { Env } from "../src/env.ts"
import { type Stub, attachmentPart, bytesOf, convId, group, intent, objectIdOf, op, post, put, result, runInDurableObject, sha, signIn, stub, testEnv, text, upload, urlFor, worker } from "./home-attachments-support.ts"

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

describe("Home attachments: re-check blockers (sweep cursor, orphan slots, required tests)", { timeout: 180_000 }, () => {
  type Inst = { nextWakeAt(s: unknown, now: number): number | null }
  const usageRows = (user: string) =>
    runInDurableObject(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)), async (_i, state) => (state.storage.sql.exec("SELECT key FROM home_attachment_usage").toArray() as Array<{ key: string }>).map((r) => r.key))
  const slotRows = (stub: unknown) => runInDurableObject(stub, async (_i, state) => state.storage.sql.exec("SELECT id, state FROM home_attachment_slots").toArray() as Array<{ id: string; state: string }>)
  const expireSlots = (stub: unknown) => runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_slots SET expires_at = ?", Date.now() - 2 * 3_600_000))
  /** Fires the alarm until the DO has no due work (at most `max` times); answers how many fired. */
  const drainAlarms = async (stub: DurableObjectStub, max = 20) => {
    let n = 0
    for (; n < max; n++) {
      const due = await runInDurableObject(stub, async (i: Inst) => i.nextWakeAt(null, Date.now()))
      if (due === null || due > Date.now()) break
      await runDurableObjectAlarm(stub)
    }
    return n
  }
  const keyOfPresigned = (uploadUrl: string) => decodeURIComponent(new URL(uploadUrl).pathname).split("/").slice(2).join("/")

  it("P1: the sweep keeps a cursor past 500 referenced old records, collects the unreferenced ones after them, and stops rescheduling", async () => {
    const alice = await signIn("att-cursor-alice")
    const g = await group(alice)
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(g.id))
    // One real upload creates the tables; then 500 referenced and 30 unreferenced old records are seeded.
    await upload(alice, g.id, bytesOf("seed"))
    const old = Date.now() - 3 * 86_400_000
    const hex = (i: number, tag: string) => createHash("sha256").update(`${tag}${i}`).digest("hex")
    await runInDurableObject(stub, async (_i, state) => {
      const sql = state.storage.sql
      for (let i = 0; i < 500; i++) {
        const h = hex(i, "ref")
        sql.exec("INSERT INTO home_attachment_objects (hash, object_id, object_key, mime_type, byte_count, etag, uploaders, quota_user, created_at) VALUES (?, ?, ?, 'image/png', 1, NULL, '[]', 'user_nobody', ?)", h, h.slice(0, 32), `home/v1/${g.id}/${h.slice(0, 32)}`, old + i)
        sql.exec("INSERT INTO own_rows (tbl, k, n, json) VALUES ('attref', ?, NULL, ?)", `${h}:msg_seed${i}`, JSON.stringify({ hash: h, message_id: `msg_seed${i}`, seq: 1 }))
      }
      for (let i = 0; i < 30; i++) {
        const h = hex(i, "orphan")
        sql.exec("INSERT INTO home_attachment_objects (hash, object_id, object_key, mime_type, byte_count, etag, uploaders, quota_user, created_at) VALUES (?, ?, ?, 'image/png', 1, NULL, '[]', 'user_nobody', ?)", h, h.slice(0, 32), `home/v1/${g.id}/${h.slice(0, 32)}`, old + 1000 + i)
      }
      sql.exec("UPDATE home_attachment_objects SET created_at = ? WHERE uploaders != '[]'", old - 1)
      sql.exec("INSERT INTO home_attachment_sweep (id, cutoff, dirty_at) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET dirty_at = excluded.dirty_at", Number.MIN_SAFE_INTEGER, Date.now() - 1)
    })
    const fired = await drainAlarms(stub)
    expect(fired).toBeGreaterThan(1)
    expect(fired).toBeLessThan(20)
    const left = await runInDurableObject(stub, async (_i, state) => (state.storage.sql.exec("SELECT COUNT(*) AS n FROM home_attachment_objects").toArray()[0] as { n: number }).n)
    // 500 referenced stay; the 30 unreferenced and the unreferenced seed upload are collected.
    expect(left).toBe(500)
    const next = await runInDurableObject(stub, async (i: Inst) => i.nextWakeAt(null, Date.now()))
    expect(next === null || next > Date.now() + 3_600_000).toBe(true)
  })

  it("P2: a slot that expires without a commit has its object deleted and its bytes refunded (open and uploading slots)", async () => {
    const alice = await signIn("att-expire-alice")
    const g = await group(alice)
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(g.id))
    const big = new Uint8Array(33_000_000).fill(3)
    const r = await intent(alice, g.id, big, { mime_type: "video/mp4", name: "x.mp4", width: undefined, height: undefined })
    const key = keyOfPresigned(r.json.value.upload_url)
    await testEnv.HOME_ATTACHMENTS.put(key, big, { sha256: sha(big) })
    // A stream slot whose PUT started (consumed) but never finished.
    const small = bytesOf("never finished")
    const s = await intent(alice, g.id, small)
    const sid = new URL(s.json.value.upload_url).pathname.split("/").pop()!.split(".")[0]!
    const conv = stub as unknown as { uploadSlot(e: string, id: string, mode: string, consume: boolean): Promise<{ object_key: string } | null> }
    const taken = await conv.uploadSlot(g.id, sid, "stream", true)
    await testEnv.HOME_ATTACHMENTS.put(taken!.object_key, small)
    expect(await usageRows(alice.user)).toHaveLength(2)
    await expireSlots(stub)
    await drainAlarms(stub)
    expect(await testEnv.HOME_ATTACHMENTS.head(key)).toBeNull()
    expect(await testEnv.HOME_ATTACHMENTS.head(taken!.object_key)).toBeNull()
    expect(await slotRows(stub)).toEqual([])
    expect(await usageRows(alice.user)).toEqual([])
  })

  it("P2: an 'exists' commit deletes the slot's object at once, refunds, and refuses a later PUT; a presigned re-PUT is deleted at URL expiry", async () => {
    const alice = await signIn("att-exists-alice")
    const bob = await signIn("att-exists-bob")
    const g = await group(alice, [bob])
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(g.id))
    // Stream: Bob uploads bytes Alice already uploaded (not visible to him, so he gets a slot).
    const body = bytesOf("same bytes twice")
    await upload(alice, g.id, body)
    const r = await intent(bob, g.id, body)
    expect(r.json.value.state).toBe("upload")
    const first = await put(r.json.value.upload_url, body)
    expect(((await first.json()) as any).value.state).toBe("exists")
    expect(await usageRows(bob.user)).toEqual([])
    expect((await put(r.json.value.upload_url, body)).status).toBe(403)
    expect((await testEnv.HOME_ATTACHMENTS.list({ prefix: `home/v1/${g.id}/` })).objects).toHaveLength(1)

    // Presigned: Bob's commit finds Alice's object; his object goes now, and a re-PUT before the URL expires is deleted at expiry.
    const big = new Uint8Array(33_000_000).fill(5)
    const aliceBig = await intent(alice, g.id, big, { mime_type: "video/mp4", name: "a.mp4", width: undefined, height: undefined })
    await testEnv.HOME_ATTACHMENTS.put(keyOfPresigned(aliceBig.json.value.upload_url), big, { sha256: sha(big) })
    expect((await post("/v1/home/attachments/commit", alice.token, { conversation: g.id, slot: aliceBig.json.value.slot })).json.value.state).toBe("stored")
    const bobBig = await intent(bob, g.id, big, { mime_type: "video/mp4", name: "b.mp4", width: undefined, height: undefined })
    const bobKey = keyOfPresigned(bobBig.json.value.upload_url)
    await testEnv.HOME_ATTACHMENTS.put(bobKey, big, { sha256: sha(big) })
    const committed = await post("/v1/home/attachments/commit", bob.token, { conversation: g.id, slot: bobBig.json.value.slot })
    expect(committed.json.value.state).toBe("exists")
    expect(await testEnv.HOME_ATTACHMENTS.head(bobKey)).toBeNull()
    expect(await usageRows(bob.user)).toEqual([])
    expect((await post("/v1/home/attachments/commit", bob.token, { conversation: g.id, slot: bobBig.json.value.slot })).status).toBe(403)
    await testEnv.HOME_ATTACHMENTS.put(bobKey, big, { sha256: sha(big) })
    await expireSlots(stub)
    await drainAlarms(stub)
    expect(await testEnv.HOME_ATTACHMENTS.head(bobKey)).toBeNull()
    expect(await slotRows(stub)).toEqual([])
  })

  it("commit rechecks the archived state", async () => {
    const alice = await signIn("att-archived-alice")
    const id = convId()
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id)) as unknown as Stub & {
      createUploadSlot(e: string, actor: string, quotaUser: string, meta: unknown, mode: string, id?: string): Promise<{ id: string; object_key: string } | null>
      uploadSlot(e: string, id: string, mode: string, consume: boolean): Promise<unknown>
      commitAttachment(e: string, slotId: string, etag?: string): Promise<{ ok: boolean; code?: string }>
    }
    const agent = "agent_att_archived_chief"
    const owner = { ...alice.principal, owned_agents: [{ id: agent, display_name: "Chief" }] } as Principal
    expect(result(await conv.submit(id, owner, { t: "op", op: "conversation.create", params: { id, kind: "group", title: "A", participants: [{ id: alice.user, kind: "human", display_name: "A" }, { id: agent, kind: "agent", display_name: "Chief", agent_class: "mux" }] }, idempotency_key: "c" }))).toMatchObject({ t: "result" })
    const body = bytesOf("agent upload")
    const slot = await conv.createUploadSlot(id, agent, alice.user, { hash: sha(body), byte_count: body.byteLength, mime_type: "image/png" }, "stream", "0".repeat(31) + "a")
    expect(slot).not.toBeNull()
    await conv.uploadSlot(id, slot!.id, "stream", true)
    // The last human leaves: the conversation is archived while the chief stays a participant.
    expect(result(await conv.submit(id, alice.principal, { t: "op", op: "participants.remove", params: { participant: alice.user }, idempotency_key: "leave" }))).toMatchObject({ t: "result" })
    expect(await conv.commitAttachment(id, slot!.id)).toMatchObject({ ok: false, code: "archived" })
  })

  it("a presigned upload whose size differs from the intent is refused at commit and deleted", async () => {
    const alice = await signIn("att-size-alice")
    const g = await group(alice)
    const declared = new Uint8Array(33_000_000).fill(1)
    const r = await intent(alice, g.id, declared, { mime_type: "video/mp4", name: "s.mp4", width: undefined, height: undefined })
    const key = keyOfPresigned(r.json.value.upload_url)
    const shorter = declared.subarray(0, declared.byteLength - 1)
    await testEnv.HOME_ATTACHMENTS.put(key, shorter, { sha256: sha(shorter) })
    const c = await post("/v1/home/attachments/commit", alice.token, { conversation: g.id, slot: r.json.value.slot })
    expect(c.status).toBe(400)
    expect(c.json.error.code).toBe("attachment.size_mismatch")
    expect(await testEnv.HOME_ATTACHMENTS.head(key)).toBeNull()
  })

  it("files over 32 MB answer 503 attachment.large_unavailable without the S3 settings", async () => {
    const alice = await signIn("att-nos3-alice")
    const g = await group(alice)
    const { handleAttachmentIntent } = await import("../src/home-attachments.ts")
    const noS3 = { ...testEnv, HOME_ATTACHMENTS_S3_ENDPOINT: undefined } as Env
    const req = new Request("https://api.test/v1/home/attachments/intent", {
      method: "POST",
      headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
      body: JSON.stringify({ conversation: g.id, sha256: "a".repeat(64), byte_count: 40_000_000, mime_type: "video/mp4", name: "v.mp4" })
    })
    const res = await handleAttachmentIntent(req, noS3)
    expect(res.status).toBe(503)
    expect(((await res.json()) as any).error.code).toBe("attachment.large_unavailable")
  })
})
