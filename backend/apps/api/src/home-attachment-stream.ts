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

/** A streaming part's claim renewal: `run` every `everyMs` while bytes arrive; false means the claim is gone. */
export interface PartRenewal {
  readonly everyMs: number
  readonly run: () => Promise<boolean>
}

/**
 * Streams one multipart part (exactly `length` bytes) into R2 part `part`, hashing it onto `sha`.
 * Null when the body has another length or `renew` reports the claim gone (the stream fails before
 * the next bytes, so R2 keeps none of this upload). "unavailable" when R2 or the network failed a
 * body that was fine so far: the client sends the same part again (the hash state is the slot's,
 * untouched by this request). R2 keeps nothing until the completion.
 */
export const streamPartInto = async (upload: R2MultipartUpload, part: number, request: Request, length: number, sha: ResumableSha256, renew?: PartRenewal): Promise<R2UploadedPart | null | "unavailable"> => {
  if (!request.body || request.headers.get("content-length") !== String(length)) return null
  let count = 0
  let renewedAt = Date.now()
  // The body's own fault (too long, too short, or a claim that lapsed): no retry of the same request fixes it here.
  let refused = false
  const meter = new TransformStream<Uint8Array, Uint8Array>({
    async transform(chunk, ctl) {
      count += chunk.byteLength
      if (count > length) {
        refused = true
        return ctl.error(new Error("body longer than declared"))
      }
      if (renew && Date.now() - renewedAt >= renew.everyMs) {
        renewedAt = Date.now()
        // A claim that cannot be confirmed may have lapsed: stop rather than risk replacing another request's part.
        if (!(await renew.run().catch(() => false))) {
          refused = true
          return ctl.error(new Error("the part's claim was not renewed"))
        }
      }
      sha.update(chunk)
      ctl.enqueue(chunk)
    },
    flush() {
      if (count !== length) refused = true
      // Every byte passed the claim checks above: while R2 writes the part and has not answered, the claim keeps
      // renewing, so a slow R2 answer never lets another request take a part this one may still write. Only now:
      // while bytes stream, the per-chunk check renews and stops a request whose claim was taken.
      else if (renew)
        heartbeat = setInterval(() => {
          if (Date.now() - renewedAt < renew.everyMs) return
          renewedAt = Date.now()
          void renew.run().catch(() => false)
        }, HEARTBEAT_TICK_MS)
    }
  })
  // Stops when uploadPart settles (finally below).
  let heartbeat: ReturnType<typeof setInterval> | undefined
  const fixed = new FixedLengthStream(length)
  const piped = request.body.pipeThrough(meter).pipeTo(fixed.writable).catch(() => undefined)
  try {
    const uploaded = await upload.uploadPart(part, fixed.readable)
    await piped
    return count === length ? uploaded : null
  } catch {
    await fixed.readable.cancel().catch(() => undefined)
    await piped
    return refused ? null : "unavailable"
  } finally {
    if (heartbeat !== undefined) clearInterval(heartbeat)
  }
}

/** How often a part's heartbeat looks at its claim's age (it renews only once PART_RENEW_MS passed). */
const HEARTBEAT_TICK_MS = 1_000

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

/**
 * Error codes of a multipart completion that no retry can fix: the parts cannot form the file.
 * R2's numeric codes (InvalidPart 10025, EntityTooSmall 10011, BadDigest 10037, BadUpload 10048)
 * and the self-hosted bucket's FsBucketError codes. NoSuchUpload (10024) means the upload is
 * closed: completed (its answer lost) or aborted. Any other error is transient.
 */
const INTEGRITY_CODES: ReadonlySet<number | string> = new Set([10011, 10025, 10037, 10048, "InvalidPart", "InvalidPartOrder", "EntityTooSmall", "BadDigest", "BadUpload"])
const CLOSED_CODES: ReadonlySet<number | string> = new Set([10024, "NoSuchUpload"])
/**
 * The error's code: `code` where the runtime sets it (R2Error.code, FsBucketError.code); else the
 * R2 v4 code the binding appends to every R2 error as "(<code>)" (workerd's local binding throws a
 * plain Error that carries only that). Never the message's words.
 */
const errorCode = (error: unknown): number | string | undefined => {
  if (typeof error !== "object" || error === null) return undefined
  const code = (error as { code?: unknown }).code
  if (typeof code === "number" || typeof code === "string") return code
  const v4 = /\((\d{5,6})\)$/.exec(String((error as { message?: unknown }).message ?? ""))
  return v4 ? Number(v4[1]) : undefined
}
export const completionFailure = (error: unknown): "integrity" | "closed" | "transient" => {
  const code = errorCode(error)
  return code === undefined ? "transient" : INTEGRITY_CODES.has(code) ? "integrity" : CLOSED_CODES.has(code) ? "closed" : "transient"
}
