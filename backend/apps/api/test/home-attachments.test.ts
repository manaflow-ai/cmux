/** Home attachments (home-messaging.md section 10.1): intent, upload, dedupe, downloads, retention. Helpers: home-attachments-support.ts. */
import { describe, expect, it } from "vitest"
import { attachmentPart, bytesOf, group, intent, objectIdOf, op, post, put, sha, signIn, testEnv, text, upload, urlFor, worker } from "./home-attachments-support.ts"

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

  it("refuses types off the owner's list (any name attaches) and accepts large originals", async () => {
    const alice = await signIn("att-type-alice")
    const { id } = await group(alice)
    const body = bytesOf("<svg/>")
    expect((await intent(alice, id, body, { mime_type: "image/svg+xml", name: "x.svg" })).status).toBe(415)
    expect((await intent(alice, id, body, { mime_type: "text/html", name: "index.html" })).status).toBe(415)
    expect((await intent(alice, id, body, { mime_type: "text/plain", name: "index.html" })).status).toBe(200)
    expect((await intent(alice, id, bytesOf("\u0000bin"), { mime_type: "application/octet-stream", name: "setup.exe" })).status).toBe(200)
    const big = await intent(alice, id, body, { byte_count: 100_000_001 })
    expect(big.status).toBe(200)
  })

  it("takes the daily intent quota per user; every slot is charged, also a repeated intent for the same hash", async () => {
    const alice = await signIn("att-quota-alice")
    const { id } = await group(alice)
    const video = (i: number) => ({ sha256: sha(bytesOf(`v${i}`)), byte_count: 1_000_000, mime_type: "video/mp4", name: `v${i}.mp4`, duration_ms: 1000 })
    // Seed earlier slots through the owner: sending 300 HTTP requests at once would test
    // the separate 60/minute burst limiter instead of the rolling daily quota.
    const user = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(alice.user)) as unknown as {
      takeAttachmentQuota(entity: string, key: string, bytes: number): Promise<{ ok: boolean }>
    }
    for (let i = 0; i < 298; i++) expect(await user.takeAttachmentQuota(alice.user, `prior-${i}`, 1_000_000)).toEqual({ ok: true })
    // Both new slots for the same hash count: intents 299 and 300 pass, 301 fails.
    const request = { conversation: id, ...video(0) }
    expect((await post("/v1/home/attachments/intent", alice.token, request)).status).toBe(200)
    expect((await post("/v1/home/attachments/intent", alice.token, request)).status).toBe(200)
    const over = await post("/v1/home/attachments/intent", alice.token, request)
    expect(over.status).toBe(429)
    expect(over.json.error.code).toBe("attachment.quota")
    expect(over.json.error.message).toBe("attachment quota reached (day_intents)")
    expect(over.json.error.retry_after_ms).toBeGreaterThan(0)
  })
})

describe("Home attachments: upload and dedupe", { timeout: 60_000 }, () => {
  it("streams an original as ordered parts; each part PUT and the completion make the same R2 calls whatever the file's size", async () => {
    const alice = await signIn("att-multipart-alice")
    const { id } = await group(alice)
    const { handleAttachmentMultipartComplete, handleAttachmentMultipartPart } = await import("../src/home-attachments.ts")
    // Workers cap subrequests per invocation: count every R2 call each request makes.
    const counted = (calls: Array<string>) => {
      const wrap = <T extends object>(target: T, name: string): T =>
        new Proxy(target, {
          get(t, p) {
            const v = Reflect.get(t, p) as unknown
            if (typeof v !== "function") return v
            return (...args: Array<unknown>) => {
              calls.push(`${name}.${String(p)}`)
              const out = v.apply(t, args)
              if (p === "resumeMultipartUpload") return wrap(out, "upload")
              return p === "createMultipartUpload" ? out.then((u: object) => wrap(u, "upload")) : out
            }
          }
        })
      return { ...testEnv, HOME_ATTACHMENTS: wrap(testEnv.HOME_ATTACHMENTS, "bucket") }
    }
    const run = async (body: Uint8Array) => {
      const r = await intent(alice, id, body, { multipart: true, mime_type: "application/octet-stream", name: "a.bin", width: undefined, height: undefined })
      expect(r.json.value).toMatchObject({ state: "upload", mode: "multipart", method: "PUT" })
      const size = r.json.value.part_size as number
      const token = new URL(r.json.value.upload_url).pathname.split("/").pop()!
      const putPart = (piece: Uint8Array, part: number, env: object = testEnv) =>
        handleAttachmentMultipartPart(new Request(r.json.value.upload_url, { method: "PUT", body: piece, headers: { "content-length": String(piece.byteLength), "x-cmux-part-number": String(part) } }), env as typeof testEnv, id, token)
      expect((await putPart(new Uint8Array([1]), 1)).status).toBe(400)
      const puts: Array<string> = []
      const parts: Array<{ part_number: number; byte_count: number; etag: string }> = []
      for (let start = 0, part = 1; start < body.length; start += size, part++) {
        const piece = body.subarray(start, start + size)
        const calls: Array<string> = []
        const res = await putPart(piece, part, counted(calls))
        expect(res.status).toBe(200)
        const stored = { part_number: part, byte_count: piece.byteLength, etag: ((await res.json()) as any).value.etag as string }
        parts.push(stored)
        puts.push(calls.join())
        // A repeated PUT of a stored part never reaches R2, so the stored part stays; it answers the stored part (a lost answer's retry).
        const replayCalls: Array<string> = []
        const replay = await putPart(piece, part, counted(replayCalls))
        expect([replay.status, ((await replay.json()) as any).value]).toEqual([200, stored])
        expect(replayCalls).toEqual([])
      }
      const complete = (list: Array<unknown>, env: object = testEnv) =>
        handleAttachmentMultipartComplete(
          new Request("https://api.test/v1/home/attachments/multipart/complete", { method: "POST", headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" }, body: JSON.stringify({ conversation: id, slot: r.json.value.slot, parts: list }) }),
          env as typeof testEnv
        )
      expect((await complete(parts.map((part) => ({ ...part, etag: "other" })))).status).toBe(409)
      const calls: Array<string> = []
      expect((await complete(parts, counted(calls))).status).toBe(200)
      const downloaded = new Uint8Array(await (await worker.fetch((await urlFor(alice, id, sha(body))).json.value.url)).arrayBuffer())
      expect([downloaded.byteLength, sha(downloaded)]).toEqual([body.byteLength, sha(body)])
      return { puts, complete: calls }
    }
    const one = await run(new Uint8Array(32_000_017).fill(1))
    const two = await run(new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => i % 251))
    expect([one.puts.length, two.puts.length]).toEqual([1, 2])
    expect(new Set([...one.puts, ...two.puts]).size).toBe(1)
    expect(two.complete).toEqual(one.complete)
    // No temporary objects: each file is one object.
    expect((await testEnv.HOME_ATTACHMENTS.list({ prefix: `home/v1/${id}/` })).objects).toHaveLength(2)
  })

  it("a part number is an integer from 1 to the planned part count (at most 10,000), on every part PUT and in the completion's list", async () => {
    const alice = await signIn("att-multipart-numbers")
    const { id } = await group(alice)
    const body = new Uint8Array(32 * 1024 * 1024 + 17)
    const r = await intent(alice, id, body, { multipart: true })
    expect(r.json.value.part_count).toBe(2)
    for (const number of ["0", "3", "10000", "10001", "99999999999999", "1.5", "01", "-1", ""]) {
      const res = await worker.fetch(r.json.value.upload_url, { method: "PUT", body: new Uint8Array([1]), headers: { "content-length": "1", "x-cmux-part-number": number } })
      expect([number, res.status, ((await res.json()) as any).error.code]).toEqual([number, 400, "attachment.part_invalid"])
    }
    for (const parts of [[{ part_number: 10_001, etag: "e" }], [{ part_number: 1, etag: "e" }, { part_number: 3, etag: "e" }], [{ part_number: 1.5, etag: "e" }], [{ part_number: 1, etag: "e" }, { part_number: 2, etag: "e" }, { part_number: 3, etag: "e" }]]) {
      const res = await post("/v1/home/attachments/multipart/complete", alice.token, { conversation: id, slot: r.json.value.slot, parts })
      expect([parts.length, res.status, res.json.error.code]).toEqual([parts.length, 400, "attachment.parts_invalid"])
    }
  })

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
