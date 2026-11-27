/** Home attachments: multipart part claims, stale part writes and a recorded part's retry. Helpers: home-attachments-multipart-support.ts. */
import { afterEach, describe, expect, it, vi } from "vitest"

import { group, runInDurableObject, sha, signIn, testEnv, urlFor } from "./home-attachments-support.ts"
import { downloaded, gatedBody, multipart, ownerWith } from "./home-attachments-multipart-support.ts"

describe("Home attachments: a part keeps its claim until R2 answers, and a recorded part's retry answers its stored result", { timeout: 120_000 }, () => {
  afterEach(() => void vi.useRealTimers())

  it("a part whose bytes all arrived but whose R2 write is slow keeps renewing its claim: another request for it stays busy, and the slow one records", async () => {
    const alice = await signIn("att-claim-slow-r2")
    const { id } = await group(alice)
    const { PART_CLAIM_MS, PART_RENEW_MS } = await import("../src/home-attachment-store.ts")
    const { handleAttachmentMultipartPart } = await import("../src/home-attachments.ts")
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => (i * 3) % 191)
    const m = await multipart(alice, id, body)
    let written!: () => void
    const wrote = new Promise<void>((r) => (written = r))
    let release!: () => void
    const gate = new Promise<void>((r) => (release = r))
    const bucket = testEnv.HOME_ATTACHMENTS
    const own = (x: object, q: string | symbol) => {
      const v = Reflect.get(x, q)
      return typeof v === "function" ? v.bind(x) : v
    }
    const slow = new Proxy(bucket, {
      get(t, p) {
        if (p !== "resumeMultipartUpload") return own(t, p)
        return (key: string, uploadId: string) =>
          new Proxy(t.resumeMultipartUpload(key, uploadId), {
            get: (u, q) =>
              q === "uploadPart"
                ? async (n: number, value: ReadableStream) => {
                    const done = await u.uploadPart(n, value)
                    written()
                    await gate
                    return done
                  }
                : own(u, q)
          })
      }
    })
    const t0 = Date.now()
    const first = handleAttachmentMultipartPart(new Request(m.uploadUrl, { method: "PUT", body: body.subarray(0, m.size), headers: { "content-length": String(m.size), "x-cmux-part-number": "1" } }), { ...testEnv, HOME_ATTACHMENTS: slow }, id, m.token)
    await wrote
    // R2 has every byte and has not answered: past one renewal interval the claim is renewed while it waits.
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(t0 + PART_RENEW_MS + 1_000)
    await new Promise((r) => setTimeout(r, 2_500))
    // Past the first claim's timeout: the part is still this request's.
    vi.setSystemTime(t0 + PART_CLAIM_MS + 1_000)
    const busy = await m.putPart(1)
    expect([busy.status, busy.json.error?.code]).toEqual([409, "attachment.part_busy"])
    release()
    expect((await first).status).toBe(200)
    vi.useRealTimers()
    expect((await m.putPart(2)).status).toBe(200)
    const done = await m.complete()
    expect([done.status, done.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })

  it("a part whose record committed but whose answer was lost is sent again: the retry answers the stored part, and the upload goes on", async () => {
    const alice = await signIn("att-part-ack-lost")
    const { id } = await group(alice)
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => (i * 7) % 197)
    const m = await multipart(alice, id, body)
    const lostAnswer = ownerWith({
      recordMultipartPart: async (stub, ...args: Array<unknown>) => {
        await stub.recordMultipartPart(...args)
        throw new Error("Network connection lost.")
      }
    })
    await expect(m.putPart(1, undefined, lostAnswer)).rejects.toThrow("Network connection lost.")
    const retried = await m.putPart(1)
    expect([retried.status, retried.json.value?.part_number, retried.json.value?.byte_count]).toEqual([200, 1, m.size])
    expect(typeof retried.json.value?.etag).toBe("string")
    expect((await m.putPart(2)).status).toBe(200)
    const done = await m.complete()
    expect([done.status, done.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })
})

describe("Home attachments: a request that lost its part's claim changes nothing and is told to send again", { timeout: 120_000 }, () => {
  it("a stale last part with other bytes, whose claim another request took while R2 wrote it, neither ends the slot nor aborts the upload; its answer is retryable", async () => {
    const alice = await signIn("att-stale-last-part")
    const { id } = await group(alice)
    const { handleAttachmentMultipartPart } = await import("../src/home-attachments.ts")
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => (i * 5) % 199)
    const m = await multipart(alice, id, body)
    expect((await m.putPart(1)).status).toBe(200)
    let written!: () => void
    const wrote = new Promise<void>((r) => (written = r))
    let release!: () => void
    const gate = new Promise<void>((r) => (release = r))
    const bucket = testEnv.HOME_ATTACHMENTS
    const own = (x: object, q: string | symbol) => {
      const v = Reflect.get(x, q)
      return typeof v === "function" ? v.bind(x) : v
    }
    const slow = new Proxy(bucket, {
      get(t, p) {
        if (p !== "resumeMultipartUpload") return own(t, p)
        return (key: string, uploadId: string) =>
          new Proxy(t.resumeMultipartUpload(key, uploadId), {
            get: (u, q) =>
              q === "uploadPart"
                ? async (n: number, value: ReadableStream) => {
                    const done = await u.uploadPart(n, value)
                    written()
                    await gate
                    return done
                  }
                : own(u, q)
          })
      }
    })
    const wrong = new Uint8Array(17).fill(0xee)
    const stale = handleAttachmentMultipartPart(new Request(m.uploadUrl, { method: "PUT", body: wrong, headers: { "content-length": "17", "x-cmux-part-number": "2" } }), { ...testEnv, HOME_ATTACHMENTS: slow }, id, m.token)
    await wrote
    // Another request takes part 2 while R2 writes the stale one.
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
    await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_slots SET part_claim = '2:other', part_claim_at = ? WHERE id = ?", Date.now(), m.slot))
    release()
    const res = await stale
    const json = (await res.json()) as any
    expect([res.status, json.error?.code, json.error?.retryable]).toEqual([409, "attachment.part_order", true])
    const row = await runInDurableObject(stub, async (_i, state) => state.storage.sql.exec("SELECT state FROM home_attachment_slots WHERE id = ?", m.slot).toArray()[0] as { state: string })
    expect(row.state).toBe("open")
    // The other request ends without recording; the right bytes then complete the upload.
    await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_slots SET part_claim = NULL, part_claim_at = NULL WHERE id = ?", m.slot))
    expect((await m.putPart(2)).status).toBe(200)
    const done = await m.complete()
    expect([done.status, done.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })
})

describe("Home attachments: a stale part write that lands after a newer one never commits other bytes", { timeout: 120_000 }, () => {
  afterEach(() => void vi.useRealTimers())

  it("a request whose claim lapsed while the owner was unreachable writes its part last: the completion never stores those bytes, and the request is told to send again", async () => {
    const alice = await signIn("att-stale-write-last")
    const { id } = await group(alice)
    const { PART_CLAIM_MS } = await import("../src/home-attachment-store.ts")
    const { handleAttachmentMultipartPart } = await import("../src/home-attachments.ts")
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => (i * 9) % 211)
    const m = await multipart(alice, id, body)
    let reached!: () => void
    const atR2 = new Promise<void>((r) => (reached = r))
    let release!: () => void
    const gate = new Promise<void>((r) => (release = r))
    const bucket = testEnv.HOME_ATTACHMENTS
    const own = (x: object, q: string | symbol) => {
      const v = Reflect.get(x, q)
      return typeof v === "function" ? v.bind(x) : v
    }
    // The stale request's R2 write happens only after the gate: after the newer request's write and record.
    const late = new Proxy(bucket, {
      get(t, p) {
        if (p !== "resumeMultipartUpload") return own(t, p)
        return (key: string, uploadId: string) =>
          new Proxy(t.resumeMultipartUpload(key, uploadId), {
            get: (u, q) =>
              q === "uploadPart"
                ? async (n: number, value: ReadableStream) => {
                    const bytes = new Uint8Array(await new Response(value).arrayBuffer())
                    reached()
                    await gate
                    return u.uploadPart(n, bytes)
                  }
                : own(u, q)
          })
      }
    })
    // Its owner cannot be reached for renewals.
    const unreachable = ownerWith({ renewMultipartPart: async () => { throw new Error("owner unreachable") } })
    const staleBytes = new Uint8Array(m.size).fill(0x42)
    const t0 = Date.now()
    const stale = handleAttachmentMultipartPart(new Request(m.uploadUrl, { method: "PUT", body: staleBytes, headers: { "content-length": String(m.size), "x-cmux-part-number": "1" } }), { ...unreachable, HOME_ATTACHMENTS: late }, id, m.token)
    await atR2
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(t0 + PART_CLAIM_MS + 1_000)
    // The client's retry takes the lapsed claim and stores the real part 1.
    expect((await m.putPart(1)).status).toBe(200)
    release()
    const res = await stale
    const json = (await res.json()) as any
    expect([res.status, json.error?.retryable]).toEqual([409, true])
    vi.useRealTimers()
    expect((await m.putPart(2)).status).toBe(200)
    // R2 joins only the parts whose etags were recorded: the stale bytes replaced part 1, so its etag no
    // longer matches and the completion is refused (the slot ends), never committed as the declared file.
    const done = await m.complete()
    expect([done.status, done.json.error?.code]).toEqual([400, "attachment.size_mismatch"])
    expect((await urlFor(alice, id, sha(body))).json.ok).toBe(false)
  })

  it("the same stale write of the same bytes (a client's retry of its own part) is refused at completion as well: the slot ends and nothing is committed", async () => {
    const alice = await signIn("att-stale-write-same")
    const { id } = await group(alice)
    const { PART_CLAIM_MS } = await import("../src/home-attachment-store.ts")
    const { handleAttachmentMultipartPart } = await import("../src/home-attachments.ts")
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => (i * 17) % 227)
    const m = await multipart(alice, id, body)
    let reached!: () => void
    const atR2 = new Promise<void>((r) => (reached = r))
    let release!: () => void
    const gate = new Promise<void>((r) => (release = r))
    const bucket = testEnv.HOME_ATTACHMENTS
    const own = (x: object, q: string | symbol) => {
      const v = Reflect.get(x, q)
      return typeof v === "function" ? v.bind(x) : v
    }
    const late = new Proxy(bucket, {
      get(t, p) {
        if (p !== "resumeMultipartUpload") return own(t, p)
        return (key: string, uploadId: string) =>
          new Proxy(t.resumeMultipartUpload(key, uploadId), {
            get: (u, q) =>
              q === "uploadPart"
                ? async (n: number, value: ReadableStream) => {
                    const bytes = new Uint8Array(await new Response(value).arrayBuffer())
                    reached()
                    await gate
                    return u.uploadPart(n, bytes)
                  }
                : own(u, q)
          })
      }
    })
    const unreachable = ownerWith({ renewMultipartPart: async () => { throw new Error("owner unreachable") } })
    const t0 = Date.now()
    const stale = handleAttachmentMultipartPart(new Request(m.uploadUrl, { method: "PUT", body: body.slice(0, m.size), headers: { "content-length": String(m.size), "x-cmux-part-number": "1" } }), { ...unreachable, HOME_ATTACHMENTS: late }, id, m.token)
    await atR2
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(t0 + PART_CLAIM_MS + 1_000)
    expect((await m.putPart(1)).status).toBe(200)
    release()
    expect((await stale).status).toBe(409)
    vi.useRealTimers()
    expect((await m.putPart(2)).status).toBe(200)
    // R2 gives each part write its own etag, so even the same bytes no longer match the recorded one:
    // only after the owner was unreachable past a claim's lifetime, and the client starts the file again.
    const done = await m.complete()
    expect([done.status, done.json.error?.code]).toEqual([400, "attachment.size_mismatch"])
    expect((await urlFor(alice, id, sha(body))).json.ok).toBe(false)
  })

  it("a part PUT whose upload a self-hosted bucket already closed (resuming throws NoSuchUpload at once) answers slot_invalid, not a 500", async () => {
    const alice = await signIn("att-part-fs-closed")
    const { id } = await group(alice)
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => (i * 19) % 229)
    const m = await multipart(alice, id, body)
    const bucket = testEnv.HOME_ATTACHMENTS
    const closed = new Proxy(bucket, {
      get(t, p) {
        if (p === "resumeMultipartUpload") return () => { throw Object.assign(new Error("NoSuchUpload"), { code: "NoSuchUpload" }) }
        const v = Reflect.get(t, p)
        return typeof v === "function" ? v.bind(t) : v
      }
    })
    const res = await m.putPart(1, undefined, { ...testEnv, HOME_ATTACHMENTS: closed })
    expect([res.status, res.json.error?.code]).toEqual([403, "attachment.slot_invalid"])
    // The claim was released: the part uploads at once where the upload is open.
    expect((await m.putPart(1)).status).toBe(200)
  })
})

describe("Home attachments: a stalled part whose claim was taken never writes, however long it waited", { timeout: 120_000 }, () => {
  afterEach(() => void vi.useRealTimers())

  it("the claim lapses and the retry stores the part; seconds later the stalled body arrives: it is refused before R2, and the file completes", async () => {
    const alice = await signIn("att-stalled-heartbeat")
    const { id } = await group(alice)
    const { PART_CLAIM_MS } = await import("../src/home-attachment-store.ts")
    const { handleAttachmentMultipartPart } = await import("../src/home-attachments.ts")
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => (i * 31) % 241)
    const m = await multipart(alice, id, body)
    const vanished = gatedBody(new Uint8Array(m.size).fill(0x6b))
    const t0 = Date.now()
    const stalled = handleAttachmentMultipartPart(new Request(m.uploadUrl, { method: "PUT", body: vanished.stream, headers: { "content-length": String(m.size), "x-cmux-part-number": "1" } }), testEnv, id, m.token)
    await vanished.started
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(t0 + PART_CLAIM_MS + 1_000)
    expect((await m.putPart(1)).status).toBe(200)
    // Real seconds pass while the stalled request waits (a renewal tick of its own may run meanwhile).
    await new Promise((r) => setTimeout(r, 2_500))
    vanished.open()
    expect((await stalled).status).toBe(409)
    vi.useRealTimers()
    expect((await m.putPart(2)).status).toBe(200)
    const done = await m.complete()
    expect([done.status, done.json.value?.state]).toEqual([200, "stored"])
    expect(sha(await downloaded(alice, id, sha(body)))).toBe(sha(body))
  })
})
