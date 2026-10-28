import { createHash } from "node:crypto"

const primes = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, 157, 163, 167, 173, 179, 181, 191, 193, 197, 199, 211, 223, 227, 229, 233, 239, 241, 251, 257, 263, 269, 271, 277, 281, 283, 293, 307, 311]

/** SHA-256 constants (FIPS 180-4): fractional bits of the primes' cube and square roots. */
const K = Uint32Array.from(primes, (p) => (Math.cbrt(p) % 1) * 2 ** 32)
const H0 = Uint32Array.from(primes.slice(0, 8), (p) => (Math.sqrt(p) % 1) * 2 ** 32)
const hex = (words: Uint32Array) => Array.from(words, (w) => w.toString(16).padStart(8, "0")).join("")

/**
 * SHA-256 whose running state is a short string, so one hash spans many requests: each multipart
 * part is hashed in its own Worker invocation, which resumes from the state the owner stored after
 * the part before (node:crypto cannot export a hash's state). `state()` needs whole 64-byte blocks.
 */
export class ResumableSha256 {
  private readonly h: Uint32Array
  private readonly block = new Uint8Array(64)
  private readonly w = new Uint32Array(64)
  private fill = 0
  bytes: number

  constructor(state: string | null | undefined) {
    const [words, bytes] = state ? state.split(":") : [hex(H0), "0"]
    this.h = Uint32Array.from(words!.match(/.{8}/g)!, (x) => parseInt(x, 16))
    this.bytes = Number(bytes)
  }

  update(data: Uint8Array): void {
    this.bytes += data.byteLength
    this.absorb(data)
  }

  state(): string {
    if (this.fill) throw new Error("a part must end on a 64-byte block")
    return `${hex(this.h)}:${this.bytes}`
  }

  digest(): string {
    const pad = new Uint8Array(Math.ceil((this.fill + 9) / 64) * 64 - this.fill)
    pad[0] = 0x80
    const view = new DataView(pad.buffer)
    view.setUint32(pad.length - 8, Math.floor(this.bytes / 2 ** 29))
    view.setUint32(pad.length - 4, (this.bytes * 8) >>> 0)
    this.absorb(pad)
    return hex(this.h)
  }

  private absorb(data: Uint8Array): void {
    let i = 0
    if (this.fill) {
      i = Math.min(64 - this.fill, data.length)
      this.block.set(data.subarray(0, i), this.fill)
      this.fill += i
      if (this.fill < 64) return
      this.compress(this.block, 0)
      this.fill = 0
    }
    for (; i + 64 <= data.length; i += 64) this.compress(data, i)
    this.fill = data.length - i
    this.block.set(data.subarray(i), 0)
  }

  private compress(d: Uint8Array, o: number): void {
    const { w, h } = this
    for (let t = 0; t < 16; t++) w[t] = (d[o + 4 * t]! << 24) | (d[o + 4 * t + 1]! << 16) | (d[o + 4 * t + 2]! << 8) | d[o + 4 * t + 3]!
    for (let t = 16; t < 64; t++) {
      const x = w[t - 15]!
      const y = w[t - 2]!
      w[t] = w[t - 16]! + (((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3)) + w[t - 7]! + (((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10))
    }
    let a = h[0]!, b = h[1]!, c = h[2]!, dd = h[3]!, e = h[4]!, f = h[5]!, g = h[6]!, hh = h[7]!
    for (let t = 0; t < 64; t++) {
      const t1 = (hh + (((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7))) + ((e & f) ^ (~e & g)) + K[t]! + w[t]!) | 0
      const t2 = ((((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10))) + ((a & b) ^ (a & c) ^ (b & c))) | 0
      hh = g
      g = f
      f = e
      e = (dd + t1) | 0
      dd = c
      c = b
      b = a
      a = (t1 + t2) | 0
    }
    for (const [i, v] of [a, b, c, dd, e, f, g, hh].entries()) h[i] = h[i]! + v
  }
}

/**
 * Streams one multipart part (exactly `length` bytes) into R2 part `part`, hashing it onto `sha`.
 * Null when the body has another length or R2 refused it; R2 keeps nothing until the completion.
 */
export const streamPartInto = async (upload: R2MultipartUpload, part: number, request: Request, length: number, sha: ResumableSha256): Promise<R2UploadedPart | null> => {
  if (!request.body || request.headers.get("content-length") !== String(length)) return null
  let count = 0
  const meter = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, ctl) {
      count += chunk.byteLength
      if (count > length) return ctl.error(new Error("body longer than declared"))
      sha.update(chunk)
      ctl.enqueue(chunk)
    }
  })
  const fixed = new FixedLengthStream(length)
  const piped = request.body.pipeThrough(meter).pipeTo(fixed.writable).catch(() => undefined)
  try {
    const uploaded = await upload.uploadPart(part, fixed.readable)
    await piped
    return count === length ? uploaded : null
  } catch {
    await fixed.readable.cancel().catch(() => undefined)
    return null
  }
}

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

/** Reads all of `body` onto `sha` (a direct slot's verification step); answers the bytes read. */
export const hashInto = async (body: ReadableStream<Uint8Array>, sha: ResumableSha256): Promise<number> => {
  const reader = body.getReader()
  let count = 0
  for (let next = await reader.read(); !next.done; next = await reader.read()) {
    count += next.value.byteLength
    sha.update(next.value)
  }
  return count
}
