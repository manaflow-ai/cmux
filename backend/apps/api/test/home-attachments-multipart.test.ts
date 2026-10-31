/** Home attachments: multipart completion retries, part claims and conversation deletion. Helpers: home-attachments-support.ts, home-attachments-multipart-support.ts. */
import { afterEach, describe, expect, it, vi } from "vitest"

import { group, runInDurableObject, sha, signIn, testEnv, type Who } from "./home-attachments-support.ts"
import { completingWith, downloaded, gatedBody, multipart, ownerWith, type TestEnv } from "./home-attachments-multipart-support.ts"

describe("Home attachments: multipart completion keeps a valid upload through transient failures", { timeout: 120_000 }, () => {
  it("a completion that fails transiently (an R2 internal error, a dropped connection) keeps the slot: completing again stores the file", async () => {
    const alice = await signIn("att-complete-transient")
    const { id } = await group(alice)
    const body = new Uint8Array(32_000_017).map((_, i) => i % 239)
    const m = await multipart(alice, id, body)
    expect((await m.putPart(1)).status).toBe(200)
    for (const thrown of [Object.assign(new Error("completeMultipartUpload: We encountered an internal error. Please try again. (10001)"), { code: 10001 }), new Error("Network connection lost.")]) {
      const failed = await m.complete(completingWith(async () => Promise.reject(thrown)))
      expect([failed.status, failed.json.error.code, failed.json.error.retryable]).toEqual([503, "attachment.complete_unavailable", true])
    }
    const done = await m.complete()
    expect([done.status, done.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })

  it("a completion R2 made whose answer was lost is recognised by the object's size and hash and committed, the first time and on a retry", async () => {
    const alice = await signIn("att-complete-lost")
    const { id } = await group(alice)
    const body = new Uint8Array(32_000_017).map((_, i) => i % 241)
    const m = await multipart(alice, id, body)
    expect((await m.putPart(1)).status).toBe(200)
    const lost = await m.complete(completingWith(async (upload, parts) => {
      await upload.complete(parts)
      throw new Error("Network connection lost.")
    }))
    expect([lost.status, lost.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))

    // R2 completed, then answered an internal error: the object is there with the declared size and hash.
    const other = new Uint8Array(32_000_017).map((_, i) => (i * 7) % 253)
    const n = await multipart(alice, id, other)
    expect((await n.putPart(1)).status).toBe(200)
    const unreadable = await n.complete(completingWith(async (upload, parts) => {
      await upload.complete(parts)
      throw Object.assign(new Error("completeMultipartUpload: We encountered an internal error. Please try again. (10001)"), { code: 10001 })
    }))
    expect(unreadable.status).toBe(200)
    expect(sha(await downloaded(alice, id, sha(other)))).toBe(sha(other))

    // R2 completed and the object could not be read back either: 503, the slot stays; the retry finds the upload closed (NoSuchUpload) and the object there.
    const third = new Uint8Array(32_000_017).map((_, i) => (i * 13) % 251)
    const t = await multipart(alice, id, third)
    expect((await t.putPart(1)).status).toBe(200)
    const unknown = await t.complete(completingWith(async (upload, parts) => {
      await upload.complete(parts)
      throw new Error("Network connection lost.")
    }, async () => Promise.reject(new Error("Network connection lost."))))
    expect([unknown.status, unknown.json.error.code]).toEqual([503, "attachment.complete_unavailable"])
    const retried = await t.complete()
    expect([retried.status, retried.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(third)))).toBe(sha(third))
  })

  it("an integrity failure (R2 InvalidPart) still ends the slot and deletes its object; a closed upload with no object is not taken for a completed one", async () => {
    const alice = await signIn("att-complete-integrity")
    const { id } = await group(alice)
    const body = new Uint8Array(32_000_017).fill(9)
    const m = await multipart(alice, id, body)
    expect((await m.putPart(1)).status).toBe(200)
    // R2's own refusal: a part list whose etag names no stored part (InvalidPart).
    const bad = await m.complete(completingWith(async (upload, parts) => upload.complete(parts.map((p) => ({ ...p, etag: "0".repeat(32) })))))
    expect([bad.status, bad.json.error.code]).toEqual([400, "attachment.size_mismatch"])
    expect((await m.complete()).status).toBe(403)

    const gone = await multipart(alice, id, new Uint8Array(32_000_017).fill(8))
    expect((await gone.putPart(1)).status).toBe(200)
    const aborted = await gone.complete(completingWith(async (upload, parts) => {
      await upload.abort()
      return upload.complete(parts)
    }))
    expect([aborted.status, aborted.json.error.code]).toEqual([400, "attachment.size_mismatch"])
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
    const states = await runInDurableObject(stub, async (_i, state) => state.storage.sql.exec("SELECT state FROM home_attachment_slots WHERE id IN (?, ?)", m.slot, gone.slot).toArray().map((r) => (r as { state: string }).state))
    expect(states).toEqual(["tombstone", "tombstone"])
  })
})


describe("Home attachments: one request at a time uploads a multipart part", { timeout: 120_000 }, () => {
  it("two concurrent PUTs of different bytes for the same part: one uploads, the other is refused before it reaches R2, and the file completes as the winner's bytes", async () => {
    const alice = await signIn("att-part-race")
    const { id } = await group(alice)
    const { handleAttachmentMultipartPart } = await import("../src/home-attachments.ts")
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => i % 233)
    const m = await multipart(alice, id, body)
    expect(m.parts).toBe(2)
    const send = (stream: ReadableStream<Uint8Array>) =>
      handleAttachmentMultipartPart(new Request(m.uploadUrl, { method: "PUT", body: stream, headers: { "content-length": String(m.size), "x-cmux-part-number": "1" } }), testEnv, id, m.token)
    const winner = gatedBody(body.subarray(0, m.size))
    const loser = gatedBody(new Uint8Array(m.size).fill(0xee))
    const first = send(winner.stream)
    await winner.started
    // The second PUT reads the same slot state while the first is still streaming.
    const second = send(loser.stream)
    const early = await Promise.race([loser.started.then(() => null), second])
    winner.open()
    expect((await first).status).toBe(200)
    loser.open()
    const refused = early ?? (await second)
    expect(refused.status).toBe(409)
    expect(((await refused.json()) as any).error).toMatchObject({ code: "attachment.part_busy", retryable: true })
    expect((await m.putPart(2)).status).toBe(200)
    const done = await m.complete()
    expect([done.status, done.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })

  it("a part whose upload failed releases its claim at once: the same part uploads again right away", async () => {
    const alice = await signIn("att-part-retry")
    const { id } = await group(alice)
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => i % 229)
    const m = await multipart(alice, id, body)
    // Short: the R2 part fails and the request answers 400.
    expect((await m.putPart(1, body.subarray(0, 1024))).status).toBe(400)
    expect((await m.putPart(1)).status).toBe(200)
    // A claim its request never released (a Worker evicted mid-part) holds only while a part may still stream.
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
    const claim = (at: number) => runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_slots SET part_claim = '2:held', part_claim_at = ? WHERE id = ?", at, m.slot))
    await claim(Date.now())
    const busy = await m.putPart(2)
    expect([busy.status, busy.json.error.code]).toEqual([409, "attachment.part_busy"])
    await claim(Date.now() - 2 * 3_600_000)
    expect((await m.putPart(2)).status).toBe(200)
    expect((await m.complete()).status).toBe(200)
  })
})

describe("Home attachments: deleting a conversation's storage ends its open multipart uploads", { timeout: 120_000 }, () => {
  it("every open multipart slot's R2 upload is aborted, its stored parts included, and their part PUTs are refused", async () => {
    const alice = await signIn("att-delete-multipart")
    const { id } = await group(alice)
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => i % 227)
    const started = await multipart(alice, id, body)
    expect((await started.putPart(1)).status).toBe(200)
    const fresh = await multipart(alice, id, new Uint8Array(32 * 1024 * 1024 + 17).fill(4))
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
    const uploads = await runInDurableObject(stub, async (_i, state) => state.storage.sql.exec("SELECT object_key, multipart_upload_id FROM home_attachment_slots ORDER BY id").toArray() as Array<{ object_key: string; multipart_upload_id: string }>)
    expect(uploads).toHaveLength(2)
    await (stub as unknown as { deleteAttachmentStorage(e: string): Promise<number> }).deleteAttachmentStorage(id)
    for (const u of uploads) await expect(testEnv.HOME_ATTACHMENTS.resumeMultipartUpload(u.object_key, u.multipart_upload_id).uploadPart(2, new Uint8Array(17))).rejects.toThrow(/10024|does not exist/)
    // The Worker refuses the slots' part PUTs too: nothing reaches R2 for a deleted conversation.
    expect((await started.putPart(2)).status).toBe(403)
    expect((await fresh.putPart(1)).status).toBe(403)
  })
})

describe("Home attachments: a completion whose owner commit was lost is recovered by the slot's owner", { timeout: 120_000 }, () => {
  /** A slot whose R2 completion happened and whose owner commit failed (a dropped ConversationDO call): the slot stays `uploading`. */
  const committedNowhere = async (alice: Who, id: string, body: Uint8Array) => {
    const m = await multipart(alice, id, body)
    expect((await m.putPart(1)).status).toBe(200)
    const dropped = ownerWith({ commitAttachment: async () => Promise.reject(new Error("Network connection lost.")) })
    await expect(m.complete(dropped)).rejects.toThrow(/Network connection lost/)
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
    const row = await runInDurableObject(stub, async (_i, state) => state.storage.sql.exec("SELECT state, object_key FROM home_attachment_slots WHERE id = ?", m.slot).toArray()[0] as { state: string; object_key: string })
    expect(row.state).toBe("uploading")
    expect((await testEnv.HOME_ATTACHMENTS.head(row.object_key))?.size).toBe(body.byteLength)
    return m
  }

  it("the owner's retry verifies the joined object and commits it; another participant still gets 403", async () => {
    const alice = await signIn("att-commit-lost-alice")
    const bob = await signIn("att-commit-lost-bob")
    const { id } = await group(alice, [bob])
    const body = new Uint8Array(32_000_017).map((_, i) => i % 199)
    const m = await committedNowhere(alice, id, body)
    const other = await m.complete(testEnv, bob)
    expect([other.status, other.json.error.code]).toEqual([403, "attachment.slot_invalid"])
    const retried = await m.complete()
    expect([retried.status, retried.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
    // Committed once: the slot is gone, so a later retry is refused and the object stays.
    expect((await m.complete()).status).toBe(403)
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })

  it("two retries that both find the joined object commit it once, and the later one never deletes it", async () => {
    const alice = await signIn("att-commit-lost-race")
    const { id } = await group(alice)
    const body = new Uint8Array(32_000_017).map((_, i) => (i * 3) % 197)
    const m = await committedNowhere(alice, id, body)
    let reached!: () => void
    let open!: () => void
    const atCommit = new Promise<void>((r) => (reached = r))
    const gate = new Promise<void>((r) => (open = r))
    const held = ownerWith({
      commitAttachment: async (stub, ...args) => {
        reached()
        await gate
        return stub.commitAttachment(...args)
      }
    })
    const first = m.complete(held)
    expect(await Promise.race([atCommit.then(() => "at commit"), first.then((r) => `answered ${r.status}`)])).toBe("at commit")
    const second = await m.complete()
    expect([second.status, second.json.value?.state]).toEqual([200, "stored"])
    open()
    const late = await first
    expect([late.status, late.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })
})

describe("Home attachments: a part claim left by a vanished Worker lapses while its slot lives", { timeout: 120_000 }, () => {
  afterEach(() => void vi.useRealTimers())

  it("before the claim times out the part is busy; after it, the retry takes the part, the vanished request can no longer write it, and the upload completes", async () => {
    const alice = await signIn("att-claim-lapse")
    const { id } = await group(alice)
    const { PART_CLAIM_MS } = await import("../src/home-attachment-store.ts")
    const { handleAttachmentMultipartPart } = await import("../src/home-attachments.ts")
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => i % 193)
    const m = await multipart(alice, id, body)
    // A request that claims part 1, then stalls: its Worker is gone as far as the slot can tell.
    const vanished = gatedBody(new Uint8Array(m.size).fill(0x5a))
    const t0 = Date.now()
    const stalled = handleAttachmentMultipartPart(new Request(m.uploadUrl, { method: "PUT", body: vanished.stream, headers: { "content-length": String(m.size), "x-cmux-part-number": "1" } }), testEnv, id, m.token)
    await vanished.started
    const t1 = Date.now()
    // Its body is read only after its claim: the slot holds the claim now.
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
    const held = await runInDurableObject(stub, async (_i, state) => state.storage.sql.exec("SELECT part_claim FROM home_attachment_slots WHERE id = ?", m.slot).toArray()[0] as { part_claim: string | null })
    expect(held.part_claim).toMatch(/^1:/)
    // The clock is injected (no sleeps): just before the claim's timeout, then just after it.
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(t0 + PART_CLAIM_MS - 1_000)
    const busy = await m.putPart(1)
    expect([busy.status, busy.json.error?.code]).toEqual([409, "attachment.part_busy"])
    vi.setSystemTime(t1 + PART_CLAIM_MS + 1_000)
    expect((await m.putPart(1)).status).toBe(200)
    expect((await m.putPart(2)).status).toBe(200)
    // The stalled request wakes with other bytes: it lost its claim, so nothing it sends reaches the part.
    vanished.open()
    expect((await stalled).status).toBe(409)
    vi.useRealTimers()
    const done = await m.complete()
    expect([done.status, done.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })
})

describe("Home attachments: an R2 multipart upload is never left without a record that ends it", { timeout: 120_000 }, () => {
  it("an intent whose slot could not record its new upload (the owner call failed or its answer was lost) aborts that upload", async () => {
    const alice = await signIn("att-intent-orphan")
    const { id } = await group(alice)
    const { handleAttachmentIntent } = await import("../src/home-attachments.ts")
    const created: Array<R2MultipartUpload> = []
    const bucket = testEnv.HOME_ATTACHMENTS
    const capturing = new Proxy(bucket, {
      get(t, p) {
        if (p !== "createMultipartUpload") return (Reflect.get(t, p) as Function).bind(t)
        return async (key: string, options?: R2MultipartOptions) => {
          const upload = await t.createMultipartUpload(key, options)
          created.push(upload)
          return upload
        }
      }
    })
    const env = { ...ownerWith({ setMultipartUpload: async () => { throw new Error("owner call lost") } }), HOME_ATTACHMENTS: capturing }
    const body = JSON.stringify({ conversation: id, sha256: sha(new Uint8Array([1])), byte_count: 40_000_000, mime_type: "application/octet-stream", name: "a.bin", multipart: true })
    const request = new Request("https://api.test/v1/home/attachments/intent", { method: "POST", headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" }, body })
    await expect(handleAttachmentIntent(request, env)).rejects.toThrow("owner call lost")
    expect(created).toHaveLength(1)
    await expect(bucket.resumeMultipartUpload(created[0]!.key, created[0]!.uploadId).uploadPart(1, new Uint8Array(1))).rejects.toThrow()
  })

  it("an expired slot whose upload abort fails transiently keeps that upload queued: a later wake aborts it", async () => {
    const alice = await signIn("att-expire-abort-retry")
    const g = await group(alice)
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(g.id))
    const conv = stub as unknown as {
      createUploadSlot(e: string, actor: string, quotaUser: string, meta: unknown, mode: string, id: string): Promise<{ id: string; object_key: string }>
      setMultipartUpload(e: string, id: string, uploadId: string, objectKey?: string): Promise<boolean>
    }
    const slot = await conv.createUploadSlot(g.id, alice.user, alice.user, { hash: sha(new Uint8Array([2])), byte_count: 40_000_000, mime_type: "application/octet-stream" }, "multipart", crypto.randomUUID().replaceAll("-", ""))
    const upload = await testEnv.HOME_ATTACHMENTS.createMultipartUpload(slot.object_key)
    expect(await conv.setMultipartUpload(g.id, slot.id, upload.uploadId, slot.object_key)).toBe(true)
    // The test drives the wake: the object's own alarm (an outbox retry) would run it first with the real bucket.
    await runInDurableObject(stub, async (_i, state) => {
      state.storage.sql.exec("UPDATE home_attachment_slots SET expires_at = ?", Date.now() - 2 * 3_600_000)
      await state.storage.deleteAlarm()
    })
    const gc = await import("../src/home-attachment-gc.ts")
    const bucket = testEnv.HOME_ATTACHMENTS
    // An abort that fails with no R2 code (a dropped connection): transient, unlike NoSuchUpload.
    const failing = new Proxy(bucket, {
      get(t, p) {
        if (p !== "resumeMultipartUpload") return (Reflect.get(t, p) as Function).bind(t)
        return (key: string, uploadId: string) => {
          const u = t.resumeMultipartUpload(key, uploadId)
          return new Proxy(u, { get: (x, q) => (q === "abort" ? async () => { throw new Error("connection reset") } : (Reflect.get(x, q) as Function).bind(x)) })
        }
      }
    })
    const wake = (env: TestEnv, now: number) =>
      runInDurableObject(stub, async (inst: any) => {
        const deps = { ...inst.gc, env }
        await gc.runAttachmentWake(deps, undefined, now).catch(() => {})
        return gc.attachmentWakeAt(deps.sql)
      })
    const next = await wake({ ...testEnv, HOME_ATTACHMENTS: failing }, Date.now())
    // The upload still has a record that ends it, and the alarm comes back for it.
    expect(next).not.toBeNull()
    await upload.uploadPart(1, new Uint8Array(1))
    await wake(testEnv, Date.now() + 2 * 3_600_000)
    await expect(upload.uploadPart(1, new Uint8Array(1))).rejects.toThrow()
  })
})

/** The env with a bucket whose uploads' `abort` fails with no R2 code (a dropped connection: transient). */
const abortFailing = (): TestEnv => {
  const bucket = testEnv.HOME_ATTACHMENTS
  const own = (x: object, q: string | symbol) => {
    const v = Reflect.get(x, q)
    return typeof v === "function" ? v.bind(x) : v
  }
  const failing = (u: R2MultipartUpload) => new Proxy(u, { get: (x, q) => (q === "abort" ? async () => { throw new Error("connection reset") } : own(x, q)) })
  return {
    ...testEnv,
    HOME_ATTACHMENTS: new Proxy(bucket, {
      get(t, p) {
        if (p === "createMultipartUpload") return async (key: string, options?: R2MultipartOptions) => failing(await t.createMultipartUpload(key, options))
        if (p === "resumeMultipartUpload") return (key: string, uploadId: string) => failing(t.resumeMultipartUpload(key, uploadId))
        return own(t, p)
      }
    })
  }
}

/** Runs the owner's attachment wake at `now` with the real bucket; answers its next wake time. */
const wakeOwner = async (conversation: string, now: number) => {
  const gc = await import("../src/home-attachment-gc.ts")
  const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation))
  return runInDurableObject(stub, async (inst: any) => {
    await gc.runAttachmentWake(inst.gc, undefined, now).catch(() => {})
    return gc.attachmentWakeAt(inst.gc.sql)
  })
}

/** A multipart intent for a 40 MB file through `env`; answers the uploads it created. */
const multipartIntent = async (who: Who, conversation: string, env: TestEnv, seed: number) => {
  const { handleAttachmentIntent } = await import("../src/home-attachments.ts")
  const created: Array<R2MultipartUpload> = []
  const bucket = env.HOME_ATTACHMENTS
  const capturing = new Proxy(bucket, {
    get(t, p) {
      if (p !== "createMultipartUpload") return (Reflect.get(t, p) as Function).bind(t)
      return async (key: string, options?: R2MultipartOptions) => {
        const upload = await t.createMultipartUpload(key, options)
        created.push(testEnv.HOME_ATTACHMENTS.resumeMultipartUpload(upload.key, upload.uploadId))
        return upload
      }
    }
  })
  const body = JSON.stringify({ conversation, sha256: sha(new Uint8Array([seed])), byte_count: 40_000_000, mime_type: "application/octet-stream", name: "a.bin", multipart: true })
  const request = new Request("https://api.test/v1/home/attachments/intent", { method: "POST", headers: { authorization: `Bearer ${who.token}`, "content-type": "application/json" }, body })
  const answer = await handleAttachmentIntent(request, { ...env, HOME_ATTACHMENTS: capturing }).then((r) => r.status, (e: unknown) => e)
  return { answer, created }
}

describe("Home attachments: an upload the intent could not hand to a slot is still ended when its abort fails", { timeout: 120_000 }, () => {
  it("the slot ended before it could record the upload, and the abort failed: the owner queued it and a later wake aborts it", async () => {
    const alice = await signIn("att-intent-ended-abort")
    const { id } = await group(alice)
    const base = abortFailing()
    const env = {
      ...base,
      CONVERSATION_DO: ownerWith({
        setMultipartUpload: async (stub, ...args: Array<string>) => {
          await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_slots SET state = 'uploading' WHERE id = ?", args[1]))
          return stub.setMultipartUpload(...args)
        }
      }).CONVERSATION_DO
    }
    const { answer, created } = await multipartIntent(alice, id, env, 3)
    expect(answer).toBe(403)
    expect(created).toHaveLength(1)
    await created[0]!.uploadPart(1, new Uint8Array(1))
    expect(await wakeOwner(id, Date.now())).not.toBeNull()
    await wakeOwner(id, Date.now() + 2 * 3_600_000)
    await expect(created[0]!.uploadPart(1, new Uint8Array(1))).rejects.toThrow()
  })

  it("the owner call failed and the abort failed too: the upload is queued with the owner and a later wake aborts it", async () => {
    const alice = await signIn("att-intent-lost-abort")
    const { id } = await group(alice)
    const env = { ...abortFailing(), CONVERSATION_DO: ownerWith({ setMultipartUpload: async () => { throw new Error("owner call lost") } }).CONVERSATION_DO }
    const { answer, created } = await multipartIntent(alice, id, env, 4)
    expect(answer).toBeInstanceOf(Error)
    expect(created).toHaveLength(1)
    await created[0]!.uploadPart(1, new Uint8Array(1))
    expect(await wakeOwner(id, Date.now())).not.toBeNull()
    await wakeOwner(id, Date.now() + 2 * 3_600_000)
    await expect(created[0]!.uploadPart(1, new Uint8Array(1))).rejects.toThrow()
  })
})

describe("Home attachments: a self-hosted bucket's closed upload does not stop a completion retry", { timeout: 120_000 }, () => {
  it("the retry after a lost owner commit, where resuming the closed upload throws NoSuchUpload at once (FsBucket), finds the object and commits it", async () => {
    const alice = await signIn("att-complete-fs-closed")
    const { id } = await group(alice)
    const body = new Uint8Array(32_000_017).map((_, i) => (i * 5) % 239)
    const m = await multipart(alice, id, body)
    expect((await m.putPart(1)).status).toBe(200)
    // R2 joined the parts and the object could not be read back: 503, the slot stays.
    const unknown = await m.complete(completingWith(async (upload, parts) => {
      await upload.complete(parts)
      throw new Error("Network connection lost.")
    }, async () => Promise.reject(new Error("Network connection lost."))))
    expect([unknown.status, unknown.json.error.code]).toEqual([503, "attachment.complete_unavailable"])
    // As FsBucket does once the upload's record is gone: resuming throws synchronously.
    const bucket = testEnv.HOME_ATTACHMENTS
    const selfHosted = new Proxy(bucket, {
      get(t, p) {
        if (p === "resumeMultipartUpload") return () => { throw Object.assign(new Error("NoSuchUpload"), { code: "NoSuchUpload" }) }
        return (Reflect.get(t, p) as Function).bind(t)
      }
    })
    const retried = await m.complete({ ...testEnv, HOME_ATTACHMENTS: selfHosted })
    expect([retried.status, retried.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })
})

describe("Home attachments: a part R2 could not store right now is retryable", { timeout: 120_000 }, () => {
  it("an uploadPart that fails in R2 or the network answers 503 retryable, not a size error; the same part sent again stores and the file completes", async () => {
    const alice = await signIn("att-part-transient")
    const { id } = await group(alice)
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => (i * 11) % 251)
    const m = await multipart(alice, id, body)
    const bucket = testEnv.HOME_ATTACHMENTS
    const own = (x: object, q: string | symbol) => {
      const v = Reflect.get(x, q)
      return typeof v === "function" ? v.bind(x) : v
    }
    const flaky = new Proxy(bucket, {
      get(t, p) {
        if (p !== "resumeMultipartUpload") return own(t, p)
        return (key: string, uploadId: string) =>
          new Proxy(t.resumeMultipartUpload(key, uploadId), {
            get: (u, q) =>
              q === "uploadPart"
                ? async (_n: number, value: ReadableStream) => {
                    await value.cancel().catch(() => undefined)
                    throw new Error("uploadPart: We encountered an internal error. Please try again. (10001)")
                  }
                : own(u, q)
          })
      }
    })
    const failed = await m.putPart(1, undefined, { ...testEnv, HOME_ATTACHMENTS: flaky })
    expect([failed.status, failed.json.error?.code, failed.json.error?.retryable]).toEqual([503, "attachment.part_unavailable", true])
    expect((await m.putPart(1)).status).toBe(200)
    expect((await m.putPart(2)).status).toBe(200)
    const done = await m.complete()
    expect([done.status, done.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })
})

describe("Home attachments: the slot itself ends an upload its owner never recorded", { timeout: 120_000 }, () => {
  /** The test bucket as a self-hosted one: it can abort every open upload under a key prefix (FsBucket.abortMultipartUploads). */
  const prefixAborting = (uploads: Array<R2MultipartUpload>, calls: Array<string>) => {
    const bucket = testEnv.HOME_ATTACHMENTS
    return new Proxy(bucket, {
      get(t, p) {
        if (p === "abortMultipartUploads")
          return async (prefix: string) => {
            calls.push(prefix)
            let n = 0
            for (const u of uploads) if (u.key.startsWith(prefix)) await u.abort().then(() => n++, () => undefined)
            return n
          }
        if (p === "createMultipartUpload")
          return async (key: string, options?: R2MultipartOptions) => {
            const u = await t.createMultipartUpload(key, options)
            uploads.push(t.resumeMultipartUpload(u.key, u.uploadId))
            return u
          }
        const v = Reflect.get(t, p)
        return typeof v === "function" ? v.bind(t) : v
      }
    })
  }

  it("the owner was unreachable for the record, the abort and the queue: on a self-hosted bucket the slot's expiry aborts every upload under its key", async () => {
    const alice = await signIn("att-unrecorded-expiry")
    const { id } = await group(alice)
    const { handleAttachmentIntent } = await import("../src/home-attachments.ts")
    const gc = await import("../src/home-attachment-gc.ts")
    const uploads: Array<R2MultipartUpload> = []
    const calls: Array<string> = []
    const bucket = prefixAborting(uploads, calls)
    const failingAbort = new Proxy(bucket, {
      get(t, p) {
        if (p === "createMultipartUpload")
          return async (key: string, options?: R2MultipartOptions) => {
            const u = await (t as R2Bucket).createMultipartUpload(key, options)
            return new Proxy(u, { get: (x, q) => (q === "abort" ? async () => { throw new Error("connection reset") } : (typeof Reflect.get(x, q) === "function" ? (Reflect.get(x, q) as Function).bind(x) : Reflect.get(x, q))) })
          }
        const v = Reflect.get(t, p)
        return typeof v === "function" ? v.bind(t) : v
      }
    })
    const owner = ownerWith({
      setMultipartUpload: async () => { throw new Error("owner unreachable") },
      queueMultipartAbort: async () => { throw new Error("owner unreachable") }
    })
    const body = JSON.stringify({ conversation: id, sha256: sha(new Uint8Array([7])), byte_count: 40_000_000, mime_type: "application/octet-stream", name: "a.bin", multipart: true })
    const request = new Request("https://api.test/v1/home/attachments/intent", { method: "POST", headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" }, body })
    await expect(handleAttachmentIntent(request, { ...owner, HOME_ATTACHMENTS: failingAbort as R2Bucket })).rejects.toThrow("owner unreachable")
    expect(uploads).toHaveLength(1)
    await uploads[0]!.uploadPart(1, new Uint8Array(1))
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
    // The test drives the wake: the object's own alarm (an outbox retry) would run it first with the real bucket.
    await runInDurableObject(stub, async (_i, state) => {
      state.storage.sql.exec("UPDATE home_attachment_slots SET expires_at = ?", Date.now() - 2 * 3_600_000)
      await state.storage.deleteAlarm()
    })
    await runInDurableObject(stub, async (inst: any) => gc.runAttachmentWake({ ...inst.gc, env: { ...testEnv, HOME_ATTACHMENTS: bucket } }, undefined, Date.now()))
    expect(calls).toEqual([uploads[0]!.key])
    await expect(uploads[0]!.uploadPart(1, new Uint8Array(1))).rejects.toThrow()
  })

  it("an upload offered to a slot already past its time is refused and queued for an abort, which a wake runs", async () => {
    const alice = await signIn("att-record-expired")
    const g = await group(alice)
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(g.id))
    const conv = stub as unknown as {
      createUploadSlot(e: string, actor: string, quotaUser: string, meta: unknown, mode: string, id: string): Promise<{ id: string; object_key: string }>
      setMultipartUpload(e: string, id: string, uploadId: string, objectKey?: string): Promise<boolean>
    }
    const slot = await conv.createUploadSlot(g.id, alice.user, alice.user, { hash: sha(new Uint8Array([8])), byte_count: 40_000_000, mime_type: "application/octet-stream" }, "multipart", crypto.randomUUID().replaceAll("-", ""))
    await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_slots SET expires_at = ?", Date.now() - 1_000))
    const upload = await testEnv.HOME_ATTACHMENTS.createMultipartUpload(slot.object_key)
    expect(await conv.setMultipartUpload(g.id, slot.id, upload.uploadId, slot.object_key)).toBe(false)
    expect(await wakeOwner(g.id, Date.now())).not.toBeNull()
    await expect(upload.uploadPart(1, new Uint8Array(1))).rejects.toThrow()
  })
})

describe("Home attachments: a part row left without its slot's hash never blocks that part", { timeout: 120_000 }, () => {
  it("a stored row for part 1 whose slot still reads the old hash state: the part uploads again, replaces the row, and the file completes", async () => {
    const alice = await signIn("att-part-row-orphan")
    const { id } = await group(alice)
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => (i * 23) % 233)
    const m = await multipart(alice, id, body)
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
    await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("INSERT INTO home_attachment_parts (slot, part, etag) VALUES (?, 1, 'stale')", m.slot))
    expect((await m.putPart(1)).status).toBe(200)
    expect((await m.putPart(2)).status).toBe(200)
    const done = await m.complete()
    expect([done.status, done.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })
})

describe("Home attachments: a completion retry that fails never undoes another that succeeds", { timeout: 120_000 }, () => {
  it("completion A waits in R2; retry B fails transiently and reopens the slot; A then completes and commits the file", async () => {
    const alice = await signIn("att-complete-race")
    const { id } = await group(alice)
    const body = new Uint8Array(32_000_017).map((_, i) => (i * 29) % 239)
    const m = await multipart(alice, id, body)
    expect((await m.putPart(1)).status).toBe(200)
    let entered!: () => void
    const inR2 = new Promise<void>((r) => (entered = r))
    let release!: () => void
    const gate = new Promise<void>((r) => (release = r))
    const a = m.complete(completingWith(async (upload, parts) => {
      entered()
      await gate
      return upload.complete(parts)
    }))
    await inR2
    const b = await m.complete(completingWith(async () => {
      throw new Error("Network connection lost.")
    }, async () => Promise.reject(new Error("Network connection lost."))))
    expect([b.status, b.json.error?.code]).toEqual([503, "attachment.complete_unavailable"])
    release()
    const done = await a
    expect([done.status, done.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })
})

describe("Home attachments: a multipart intent that failed before any upload lives keeps no reservation", { timeout: 120_000 }, () => {
  const usage = (user: string) =>
    runInDurableObject(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)), async (_i, state) => (state.storage.sql.exec("SELECT key FROM home_attachment_usage").toArray() as Array<{ key: string }>).map((r) => r.key))
  const slots = (conversation: string) =>
    runInDurableObject(testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation)), async (_i, state) => state.storage.sql.exec("SELECT id FROM home_attachment_slots").toArray())
  const intentWith = async (who: Who, conversation: string, env: TestEnv, seed: number) => {
    const { handleAttachmentIntent } = await import("../src/home-attachments.ts")
    const body = JSON.stringify({ conversation, sha256: sha(new Uint8Array([seed])), byte_count: 40_000_000, mime_type: "application/octet-stream", name: "a.bin", multipart: true })
    return handleAttachmentIntent(new Request("https://api.test/v1/home/attachments/intent", { method: "POST", headers: { authorization: `Bearer ${who.token}`, "content-type": "application/json" }, body }), env)
  }

  it("R2 could not create the upload: the slot is dropped and its bytes refunded", async () => {
    const alice = await signIn("att-intent-create-fails")
    const { id } = await group(alice)
    const bucket = testEnv.HOME_ATTACHMENTS
    const failing = new Proxy(bucket, {
      get(t, p) {
        if (p === "createMultipartUpload") return async () => { throw new Error("createMultipartUpload: We encountered an internal error. Please try again. (10001)") }
        const v = Reflect.get(t, p)
        return typeof v === "function" ? v.bind(t) : v
      }
    })
    await expect(intentWith(alice, id, { ...testEnv, HOME_ATTACHMENTS: failing }, 11)).rejects.toThrow()
    expect(await slots(id)).toEqual([])
    expect(await usage(alice.user)).toEqual([])
  })

  it("the owner call that records the upload failed and the abort succeeded: the slot is dropped and its bytes refunded", async () => {
    const alice = await signIn("att-intent-record-fails")
    const { id } = await group(alice)
    const env = ownerWith({ setMultipartUpload: async () => { throw new Error("owner call lost") } })
    await expect(intentWith(alice, id, env, 12)).rejects.toThrow("owner call lost")
    expect(await slots(id)).toEqual([])
    expect(await usage(alice.user)).toEqual([])
  })

  it("the refund failed: the slot stays as its record, and its expiry refunds the bytes", async () => {
    const alice = await signIn("att-intent-refund-fails")
    const { id } = await group(alice)
    const gc = await import("../src/home-attachment-gc.ts")
    const bucket = testEnv.HOME_ATTACHMENTS
    const failing = new Proxy(bucket, {
      get(t, p) {
        if (p === "createMultipartUpload") return async () => { throw new Error("createMultipartUpload: We encountered an internal error. Please try again. (10001)") }
        const v = Reflect.get(t, p)
        return typeof v === "function" ? v.bind(t) : v
      }
    })
    const ns = testEnv.USER_DO
    const users = {
      idFromName: (n: string) => ns.idFromName(n),
      get: (uid: DurableObjectId) => {
        const stub = ns.get(uid)
        return new Proxy(stub, { get: (t, p) => (p === "refundAttachmentQuota" ? async () => { throw new Error("user owner unreachable") } : (...args: Array<unknown>) => (t as any)[p](...args)) })
      }
    } as unknown as TestEnv["USER_DO"]
    await expect(intentWith(alice, id, { ...testEnv, HOME_ATTACHMENTS: failing, USER_DO: users }, 13)).rejects.toThrow()
    expect(await slots(id)).toHaveLength(1)
    expect(await usage(alice.user)).toHaveLength(1)
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
    await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_slots SET expires_at = ?", Date.now() - 2 * 3_600_000))
    await runInDurableObject(stub, async (inst: any) => gc.runAttachmentWake(inst.gc, undefined, Date.now()))
    expect(await slots(id)).toEqual([])
    expect(await usage(alice.user)).toEqual([])
  })
})
