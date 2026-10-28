/** Home attachments: multipart completion retries, part claims and conversation deletion. Helpers: home-attachments-support.ts. */
import { afterEach, describe, expect, it, vi } from "vitest"

import { group, intent, runInDurableObject, sha, signIn, testEnv, urlFor, worker, type Who } from "./home-attachments-support.ts"

type TestEnv = typeof testEnv

/** A multipart slot of `body` and its two Worker requests, each with an optional env (a wrapped bucket). */
const multipart = async (who: Who, conversation: string, body: Uint8Array) => {
  const { handleAttachmentMultipartComplete, handleAttachmentMultipartPart } = await import("../src/home-attachments.ts")
  const r = await intent(who, conversation, body, { multipart: true, mime_type: "application/octet-stream", name: "a.bin", width: undefined, height: undefined })
  expect(r.json.value).toMatchObject({ state: "upload", mode: "multipart" })
  const size = r.json.value.part_size as number
  const token = new URL(r.json.value.upload_url).pathname.split("/").pop()!
  const putPart = async (part: number, piece: Uint8Array = body.subarray((part - 1) * size, part * size), env: TestEnv = testEnv) => {
    const res = await handleAttachmentMultipartPart(new Request(r.json.value.upload_url, { method: "PUT", body: piece, headers: { "content-length": String(piece.byteLength), "x-cmux-part-number": String(part) } }), env, conversation, token)
    return { status: res.status, json: (await res.json()) as any }
  }
  const complete = async (env: TestEnv = testEnv, as: Who = who) => {
    const res = await handleAttachmentMultipartComplete(
      new Request("https://api.test/v1/home/attachments/multipart/complete", { method: "POST", headers: { authorization: `Bearer ${as.token}`, "content-type": "application/json" }, body: JSON.stringify({ conversation, slot: r.json.value.slot }) }),
      env
    )
    return { status: res.status, json: (await res.json()) as any }
  }
  return { slot: r.json.value.slot as string, uploadUrl: r.json.value.upload_url as string, token, size, parts: r.json.value.part_count as number, putPart, complete }
}

/** The env with a bucket whose resumed uploads complete through `complete` (given the real upload). */
const completingWith = (complete: (upload: R2MultipartUpload, parts: Array<R2UploadedPart>) => Promise<R2Object>, head?: (key: string) => Promise<R2Object | null>): TestEnv => {
  const bucket = testEnv.HOME_ATTACHMENTS
  const wrapped = new Proxy(bucket, {
    get(t, p) {
      if (p === "head" && head) return head
      if (p !== "resumeMultipartUpload") return (Reflect.get(t, p) as Function).bind(t)
      return (key: string, id: string) => {
        const upload = t.resumeMultipartUpload(key, id)
        return new Proxy(upload, { get: (u, q) => (q === "complete" ? (parts: Array<R2UploadedPart>) => complete(upload, parts) : (Reflect.get(u, q) as Function).bind(u)) })
      }
    }
  })
  return { ...testEnv, HOME_ATTACHMENTS: wrapped }
}

/** The env with a conversation owner whose methods named in `override` run instead (given the real stub). */
const ownerWith = (override: Record<string, (stub: any, ...args: Array<any>) => Promise<unknown>>): TestEnv => {
  const ns = testEnv.CONVERSATION_DO
  const get = (id: DurableObjectId) => {
    const stub = ns.get(id)
    return new Proxy(stub, {
      get(t, p) {
        const own = typeof p === "string" ? override[p] : undefined
        if (own) return (...args: Array<unknown>) => own(t, ...args)
        // An RPC stub answers every name with a method; call it on the stub itself.
        return (...args: Array<unknown>) => (t as any)[p](...args)
      }
    })
  }
  return { ...testEnv, CONVERSATION_DO: { idFromName: (n: string) => ns.idFromName(n), get } as unknown as TestEnv["CONVERSATION_DO"] }
}

const downloaded = async (who: Who, conversation: string, hash: string) => new Uint8Array(await (await worker.fetch((await urlFor(who, conversation, hash)).json.value.url)).arrayBuffer())

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

/** A request body that is read only once `open` is called: `pulled` settles when the Worker starts reading it. */
const gatedBody = (bytes: Uint8Array) => {
  let pulled!: () => void
  let open!: () => void
  const started = new Promise<void>((r) => (pulled = r))
  const gate = new Promise<void>((r) => (open = r))
  const stream = new ReadableStream<Uint8Array>({
    async pull(ctl) {
      pulled()
      await gate
      ctl.enqueue(bytes)
      ctl.close()
    }
  }, { highWaterMark: 0 })
  return { stream, started, open }
}

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
