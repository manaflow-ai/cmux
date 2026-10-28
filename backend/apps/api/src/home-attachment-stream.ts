import { createHash } from "node:crypto"

/**
 * One verified PUT through the Worker into R2 (home-attachments.ts: a stream slot's file and a
 * video's poster). The body must be exactly `byteCount` bytes that hash to `sha256`; anything
 * else is deleted before this returns, so a refused upload never leaves an object behind.
 */
export type StreamResult = { readonly ok: true; readonly etag: string | undefined } | { readonly ok: false; readonly code: "attachment.size_mismatch" | "attachment.hash_mismatch" }

export type PartResult = { readonly ok: true; readonly etag: string | undefined; readonly size: number } | { readonly ok: false; readonly code: "attachment.size_mismatch" | "attachment.part_exists" }

/** Store one bounded multipart piece without buffering it in the Worker. */
export const streamPartInto = async (bucket: R2Bucket, key: string, request: Request, maxBytes: number, contentType: string): Promise<PartResult> => {
  const declared = request.headers.get("content-length")
  const length = declared === null ? null : Number(declared)
  if (!request.body || length === null || !Number.isSafeInteger(length) || length <= 0 || length !== maxBytes) return { ok: false, code: "attachment.size_mismatch" }
  let count = 0
  const meter = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, ctl) {
      count += chunk.byteLength
      if (count > length) return ctl.error(new Error("body longer than declared"))
      ctl.enqueue(chunk)
    }
  })
  const fixed = new FixedLengthStream(length)
  const piped = request.body.pipeThrough(meter).pipeTo(fixed.writable).catch(() => undefined)
  let etag: string | undefined
  try {
    // The preliminary HEAD in the route is only an early error response. The
    // conditional write is the actual single-writer guard when two PUTs race
    // for the same part (or a completion races a late PUT).
    const stored = await bucket.put(key, fixed.readable, { onlyIf: { etagDoesNotMatch: "*" }, httpMetadata: { contentType } })
    if (stored === null) {
      await fixed.readable.cancel().catch(() => undefined)
      return { ok: false, code: "attachment.part_exists" }
    }
    etag = stored.etag
    await piped
  } catch {
    // A failed conditional PUT publishes nothing. Deleting here could
    // delete a different request's successful part.
    await fixed.readable.cancel().catch(() => undefined)
    return { ok: false, code: "attachment.size_mismatch" }
  }
  if (count !== length) {
    await bucket.delete(key)
    return { ok: false, code: "attachment.size_mismatch" }
  }
  return { ok: true, etag, size: count }
}

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
