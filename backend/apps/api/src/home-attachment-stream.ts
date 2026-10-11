import { createHash } from "node:crypto"

/**
 * One verified PUT through the Worker into R2 (home-attachments.ts: a stream slot's file and a
 * video's poster). The body must be exactly `byteCount` bytes that hash to `sha256`; anything
 * else is deleted before this returns, so a refused upload never leaves an object behind.
 */
export type StreamResult = { readonly ok: true; readonly etag: string | undefined } | { readonly ok: false; readonly code: "attachment.size_mismatch" | "attachment.hash_mismatch" }

export const streamInto = async (bucket: R2Bucket, key: string, request: Request, byteCount: number, sha256: string, contentType: string): Promise<StreamResult> => {
  const declared = request.headers.get("content-length")
  if (!request.body || (declared !== null && Number(declared) !== byteCount)) return { ok: false, code: "attachment.size_mismatch" }
  const hasher = createHash("sha256")
  let count = 0
  const meter = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, ctl) {
      count += chunk.byteLength
      if (count > byteCount) return ctl.error(new Error("body longer than declared"))
      hasher.update(chunk)
      ctl.enqueue(chunk)
    }
  })
  // FixedLengthStream gives R2 the length up front and fails a body of any other length.
  const fixed = new FixedLengthStream(byteCount)
  const piped = request.body.pipeThrough(meter).pipeTo(fixed.writable).catch(() => undefined)
  let etag: string | undefined
  try {
    etag = (await bucket.put(key, fixed.readable, { httpMetadata: { contentType } }))?.etag
    await piped
  } catch {
    await bucket.delete(key)
    return { ok: false, code: "attachment.size_mismatch" }
  }
  if (count !== byteCount || hasher.digest("hex") !== sha256) {
    await bucket.delete(key)
    return { ok: false, code: "attachment.hash_mismatch" }
  }
  return { ok: true, etag }
}
