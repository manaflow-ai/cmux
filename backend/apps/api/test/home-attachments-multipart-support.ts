/** Shared helpers of the multipart attachment suites (home-attachments-multipart*.test.ts). */
import { expect } from "vitest"

import { intent, testEnv, urlFor, worker, type Who } from "./home-attachments-support.ts"

export type TestEnv = typeof testEnv

/** A multipart slot of `body` and its two Worker requests, each with an optional env (a wrapped bucket). */
export const multipart = async (who: Who, conversation: string, body: Uint8Array) => {
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
export const completingWith = (complete: (upload: R2MultipartUpload, parts: Array<R2UploadedPart>) => Promise<R2Object>, head?: (key: string) => Promise<R2Object | null>): TestEnv => {
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
export const ownerWith = (override: Record<string, (stub: any, ...args: Array<any>) => Promise<unknown>>): TestEnv => {
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

export const downloaded = async (who: Who, conversation: string, hash: string) => new Uint8Array(await (await worker.fetch((await urlFor(who, conversation, hash)).json.value.url)).arrayBuffer())


/** A request body that is read only once `open` is called: `pulled` settles when the Worker starts reading it. */
export const gatedBody = (bytes: Uint8Array) => {
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
