/**
 * Home attachments: multipart parts larger than the Worker's request body limit go straight to R2
 * with presigned UploadPart URLs; the completion then hashes the joined object back in bounded
 * steps before it is usable. Helpers: home-attachments-support.ts.
 */
import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { group, runInDurableObject, sha, signIn, testEnv, urlFor, worker, type Who } from "./home-attachments-support.ts"

const MiB = 1024 * 1024
/** A zone whose request limit (1 MB) is below the 32 MiB part: every part goes direct. */
const small = { ...testEnv, HOME_ATTACHMENT_WORKER_BODY_BYTES: "1000000" } as Env & typeof testEnv

/** Workers cap subrequests per invocation: records every R2 call a request makes. */
const counted = (calls: Array<string>) => {
  const wrap = <T extends object>(target: T, name: string): T =>
    new Proxy(target, {
      get(t, p) {
        const v = Reflect.get(t, p) as unknown
        if (typeof v !== "function") return v
        return (...args: Array<unknown>) => {
          calls.push(`${name}.${String(p)}`)
          const out = v.apply(t, args)
          return p === "resumeMultipartUpload" ? wrap(out, "upload") : out
        }
      }
    })
  return { ...small, HOME_ATTACHMENTS: wrap(small.HOME_ATTACHMENTS, "bucket") }
}

const ask = async (who: Who, conversation: string, body: Uint8Array, over: Record<string, unknown> = {}) => {
  const { handleAttachmentIntent } = await import("../src/home-attachments.ts")
  const res = await handleAttachmentIntent(
    new Request("https://api.test/v1/home/attachments/intent", {
      method: "POST",
      headers: { authorization: `Bearer ${who.token}`, "content-type": "application/json" },
      body: JSON.stringify({ conversation, sha256: sha(body), byte_count: body.byteLength, mime_type: "application/octet-stream", name: "big.bin", multipart: true, ...over })
    }),
    small
  )
  return { status: res.status, json: (await res.json()) as any }
}

/** Asks the Worker for each part's URL, then lands the bytes as the client's PUT would (on the bucket binding: tests have no S3 endpoint). */
const sendParts = async (conversation: string, answer: any, body: Uint8Array) => {
  const { handleAttachmentDirectPart } = await import("../src/home-attachments.ts")
  const token = new URL(answer.upload_url).pathname.split("/").pop()!
  const parts: Array<{ part_number: number; byte_count: number; etag: string }> = []
  for (let start = 0, part = 1; start < body.length; start += answer.part_size, part++) {
    const piece = body.subarray(start, start + answer.part_size)
    const res = await handleAttachmentDirectPart(new Request(answer.upload_url, { method: "POST", headers: { "x-cmux-part-number": String(part) } }), small, conversation, token)
    const json = (await res.json()) as any
    expect([res.status, json.error]).toEqual([200, undefined])
    const value = json.value
    expect(value).toMatchObject({ part_number: part, method: "PUT", headers: { "content-length": String(piece.byteLength) } })
    const url = new URL(value.url)
    expect(url.origin).toBe(testEnv.HOME_ATTACHMENTS_S3_ENDPOINT)
    expect([url.searchParams.get("partNumber"), url.searchParams.get("X-Amz-SignedHeaders")]).toEqual([String(part), "content-length;host"])
    const key = decodeURIComponent(url.pathname).split("/").slice(2).join("/")
    const uploaded = await testEnv.HOME_ATTACHMENTS.resumeMultipartUpload(key, url.searchParams.get("uploadId")!).uploadPart(part, piece)
    parts.push({ part_number: part, byte_count: piece.byteLength, etag: uploaded.etag })
  }
  return parts
}

const complete = async (who: Who, conversation: string, slot: string, parts: Array<unknown>, env: object = small, step = 16 * MiB) => {
  const { handleAttachmentMultipartComplete } = await import("../src/home-attachments.ts")
  const res = await handleAttachmentMultipartComplete(
    new Request("https://api.test/v1/home/attachments/multipart/complete", { method: "POST", headers: { authorization: `Bearer ${who.token}`, "content-type": "application/json" }, body: JSON.stringify({ conversation, slot, parts }) }),
    env as Env,
    undefined,
    step
  )
  return { status: res.status, json: (await res.json()) as any }
}

describe("Home attachments: parts over the Worker's request limit go straight to R2", { timeout: 180_000 }, () => {
  it("each part gets a presigned UploadPart URL; the completion hashes the object back in steps of the same bounded R2 calls, then stores it", async () => {
    const alice = await signIn("att-direct-alice")
    const { id } = await group(alice)
    const body = new Uint8Array(32 * MiB + 17).map((_, i) => i % 251)
    const r = await ask(alice, id, body)
    expect(r.status).toBe(200)
    expect(r.json.value).toMatchObject({ state: "upload", mode: "multipart", transport: "direct", part_size: 32 * MiB, part_count: 2 })
    expect(new URL(r.json.value.upload_url).pathname).toMatch(/^\/v1\/home\/attachments\/multipart\//)
    // A direct slot takes no bytes through the Worker.
    const through = await worker.fetch(r.json.value.upload_url, { method: "PUT", body: new Uint8Array(1), headers: { "content-length": "1", "x-cmux-part-number": "1" } })
    expect(through.status).toBe(403)
    const parts = await sendParts(id, r.json.value, body)
    // Etags R2 did not give: refused, and the upload stays so the client can try again.
    const wrong = await complete(alice, id, r.json.value.slot, parts.map((p) => ({ ...p, etag: "0".repeat(32) })))
    expect([wrong.status, wrong.json.error.code]).toEqual([409, "attachment.part_missing"])
    const steps: Array<string> = []
    const answers: Array<unknown> = []
    for (let i = 0; i < 10; i++) {
      const calls: Array<string> = []
      const res = await complete(alice, id, r.json.value.slot, parts, counted(calls))
      expect(res.status).toBe(200)
      answers.push(res.json.value.state === "verifying" ? res.json.value.verified_bytes : res.json.value.state)
      steps.push(calls.join())
      if (res.json.value.state !== "verifying") break
    }
    expect(answers).toEqual([16 * MiB, 32 * MiB, "stored"])
    // The first call joins the parts (one R2 call), then every call reads one bounded range.
    expect(steps[0]).toBe("bucket.resumeMultipartUpload,upload.complete,bucket.get")
    expect(new Set(steps.slice(1))).toEqual(new Set(["bucket.get"]))
    const downloaded = new Uint8Array(await (await worker.fetch((await urlFor(alice, id, sha(body))).json.value.url)).arrayBuffer())
    expect([downloaded.byteLength, sha(downloaded)]).toEqual([body.byteLength, sha(body)])
    expect((await complete(alice, id, r.json.value.slot, parts)).status).toBe(403)
  })

  it("bytes that do not hash to the declared sha256 are deleted when the last step finds it", async () => {
    const alice = await signIn("att-direct-mismatch")
    const { id } = await group(alice)
    const body = new Uint8Array(32 * MiB + 5).fill(4)
    const r = await ask(alice, id, body, { sha256: "e".repeat(64) })
    const parts = await sendParts(id, r.json.value, body)
    let last: { status: number; json: any } | undefined
    for (let i = 0; i < 10; i++) {
      last = await complete(alice, id, r.json.value.slot, parts, small, 64 * MiB)
      if (last.json.value?.state !== "verifying") break
    }
    expect([last!.status, last!.json.error.code]).toEqual([400, "attachment.hash_mismatch"])
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
    const keys = await runInDurableObject(stub, async (_i, state) => state.storage.sql.exec("SELECT object_key FROM home_attachment_slots").toArray() as Array<{ object_key: string }>)
    for (const { object_key } of keys) expect(await testEnv.HOME_ATTACHMENTS.head(object_key)).toBeNull()
  })

  it("past the Worker's limit a file needs the S3 settings; with them, every size has a transport", async () => {
    const { uploadModeFor } = await import("../src/home-attachments.ts")
    const TB = 1e12
    const code = (r: ReturnType<typeof uploadModeFor>) => (typeof r === "string" ? r : r.code)
    expect(code(uploadModeFor(2 * TB, true, true, 100_000_000))).toBe("direct")
    expect(code(uploadModeFor(40 * TB, true, true, 100_000_000))).toBe("direct")
    expect(code(uploadModeFor(2 * TB, true, false, 100_000_000))).toBe("attachment.large_unavailable")
    // A Business zone (200 MB) still carries 1.5 TB parts through the Worker.
    expect(code(uploadModeFor(1.5 * TB, true, false, 200_000_000))).toBe("multipart")
  })
})
