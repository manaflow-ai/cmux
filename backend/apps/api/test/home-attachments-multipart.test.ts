/** Home attachments: multipart completion retries, part claims and conversation deletion. Helpers: home-attachments-support.ts. */
import { describe, expect, it } from "vitest"

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
  const complete = async (env: TestEnv = testEnv) => {
    const res = await handleAttachmentMultipartComplete(
      new Request("https://api.test/v1/home/attachments/multipart/complete", { method: "POST", headers: { authorization: `Bearer ${who.token}`, "content-type": "application/json" }, body: JSON.stringify({ conversation, slot: r.json.value.slot }) }),
      env
    )
    return { status: res.status, json: (await res.json()) as any }
  }
  return { slot: r.json.value.slot as string, size, parts: r.json.value.part_count as number, putPart, complete }
}

/** The env with a bucket whose resumed uploads complete through `complete` (given the real upload). */
const completingWith = (complete: (upload: R2MultipartUpload, parts: Array<R2UploadedPart>) => Promise<R2Object>): TestEnv => {
  const bucket = testEnv.HOME_ATTACHMENTS
  const wrapped = new Proxy(bucket, {
    get(t, p) {
      if (p !== "resumeMultipartUpload") return (Reflect.get(t, p) as Function).bind(t)
      return (key: string, id: string) => {
        const upload = t.resumeMultipartUpload(key, id)
        return new Proxy(upload, { get: (u, q) => (q === "complete" ? (parts: Array<R2UploadedPart>) => complete(upload, parts) : (Reflect.get(u, q) as Function).bind(u)) })
      }
    }
  })
  return { ...testEnv, HOME_ATTACHMENTS: wrapped }
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

    // R2 completed, then the Worker could not read the object back: the retry finds the upload closed (NoSuchUpload) and the object there.
    const other = new Uint8Array(32_000_017).map((_, i) => (i * 7) % 253)
    const n = await multipart(alice, id, other)
    expect((await n.putPart(1)).status).toBe(200)
    const unreadable = await n.complete(completingWith(async (upload, parts) => {
      await upload.complete(parts)
      throw Object.assign(new Error("completeMultipartUpload: We encountered an internal error. Please try again. (10001)"), { code: 10001 })
    }))
    expect(unreadable.status).toBe(200)
    expect(sha(await downloaded(alice, id, sha(other)))).toBe(sha(other))
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
