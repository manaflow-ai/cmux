import { createHash, randomBytes } from "node:crypto"
import { createReadStream, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs"
import { open, opendir } from "node:fs/promises"
import { dirname, isAbsolute, join, posix, relative, resolve, sep } from "node:path"

/** What the attachment code reads back from a stored object (the R2 subset it uses). */
interface StoredMeta {
  readonly etag: string
  readonly size: number
  readonly contentType?: string
  readonly customMetadata?: Record<string, string>
  readonly uploaded: number
}

interface MultipartMeta {
  readonly key: string
  readonly contentType?: string
  readonly customMetadata?: Record<string, string>
}

type ObjectOptions = { httpMetadata?: { contentType?: string }; customMetadata?: Record<string, string> }
/** The metadata an object or upload keeps from its options (R2: `httpMetadata.contentType` and `customMetadata`). */
const metadataOf = (options: ObjectOptions) => ({
  ...(options.httpMetadata?.contentType ? { contentType: options.httpMetadata.contentType } : {}),
  ...(options.customMetadata && Object.keys(options.customMetadata).length ? { customMetadata: { ...options.customMetadata } } : {})
})

/** A stored object as R2 returns it, with a body when it was a `get`. */
export interface FsObject {
  readonly key: string
  readonly size: number
  readonly etag: string
  readonly httpEtag: string
  readonly uploaded: Date
  readonly httpMetadata: { contentType?: string }
  readonly customMetadata: Record<string, string>
  readonly range?: { offset: number; length: number }
  readonly body?: ReadableStream<Uint8Array>
  writeHttpMetadata(headers: Headers): void
}

/** Open multipart uploads live here, under the root but outside the key space. */
const MULTIPART_DIR = ".multipart"

const invalidKey = () => new Error("invalid object key")

/**
 * The one way a key becomes a path. A key is "/"-separated segments, none of them empty, "." or
 * "..", with no backslash, NUL or leading "/"; its normalized form must be itself, must resolve
 * strictly inside `root`, and must not start with the internal multipart directory (an inner
 * `.multipart` segment is an ordinary name).
 */
const keyPath = (root: string, key: string): string => {
  if (typeof key !== "string" || key === "" || key.startsWith("/") || /[\\\0]/.test(key)) throw invalidKey()
  if (key.split("/").some((p) => p === "" || p === "." || p === "..")) throw invalidKey()
  const normalized = posix.normalize(key)
  if (normalized !== key || isAbsolute(normalized) || normalized.split("/")[0] === MULTIPART_DIR) throw invalidKey()
  const inside = relative(resolve(root), resolve(root, normalized))
  if (!inside || inside === ".." || inside.startsWith(`..${sep}`) || isAbsolute(inside) || inside.split(sep)[0] === MULTIPART_DIR) throw invalidKey()
  return join(root, normalized)
}

const isKey = (root: string, key: string) => {
  try {
    keyPath(root, key)
    return true
  } catch {
    return false
  }
}

/** Multipart failures named as R2 (and S3) name them, so callers can tell them apart. */
export class FsBucketError extends Error {
  constructor(readonly code: "NoSuchUpload" | "InvalidPart" | "InvalidPartOrder", message: string) {
    super(`${code}: ${message}`)
    this.name = "FsBucketError"
  }
}

/** R2 numbers parts 1 to 10,000. */
const isPartNumber = (partNumber: unknown): partNumber is number => Number.isSafeInteger(partNumber) && (partNumber as number) >= 1 && (partNumber as number) <= 10_000

const noSuchUpload = () => new FsBucketError("NoSuchUpload", "the specified multipart upload does not exist")

/** An upload id is exactly what `createMultipartUpload` mints: 32 lowercase hex characters. */
const checkUploadId = (uploadId: string) => {
  if (typeof uploadId !== "string" || !/^[0-9a-f]{32}$/.test(uploadId)) throw noSuchUpload()
  return uploadId
}

const bodyStream = (value: unknown): ReadableStream<Uint8Array> => {
  if (value instanceof ReadableStream) return value
  if (value instanceof Blob) return value.stream()
  if (value === null || value === undefined) return new Blob().stream()
  if (typeof value === "string" || value instanceof ArrayBuffer) return new Blob([value]).stream()
  if (ArrayBuffer.isView(value)) return new Blob([new Uint8Array(new Uint8Array(value.buffer, value.byteOffset, value.byteLength))]).stream()
  throw new TypeError("unsupported object body")
}

/** Drain to disk with bounded memory, including short filesystem writes. */
const writeStream = async (path: string, stream: ReadableStream<Uint8Array>): Promise<{ etag: string; size: number }> => {
  const file = await open(path, "w")
  const reader = stream.getReader()
  const hash = createHash("md5")
  let size = 0
  try {
    for (;;) {
      const next = await reader.read()
      if (next.done) break
      hash.update(next.value)
      for (let offset = 0; offset < next.value.byteLength;) {
        const { bytesWritten } = await file.write(next.value.subarray(offset))
        if (bytesWritten === 0) throw new Error("filesystem write made no progress")
        offset += bytesWritten
      }
      size += next.value.byteLength
    }
    return { etag: hash.digest("hex"), size }
  } finally {
    await reader.cancel().catch(() => undefined)
    await file.close()
  }
}

/**
 * The R2 bucket subset the Home attachment code uses (`put`, `get` with range and etag match,
 * `head`, `delete`, `list` by prefix), as files under `root`. Each object is `<key>` plus
 * `<key>.meta.json`; a put writes a temp file and renames it, so a reader never sees half a file.
 */
export class FsBucket {
  constructor(private readonly root: string) {
    mkdirSync(root, { recursive: true })
  }

  private path(key: string) {
    return keyPath(this.root, key)
  }

  private meta(key: string): StoredMeta | null {
    const m = `${this.path(key)}.meta.json`
    return existsSync(m) ? (JSON.parse(readFileSync(m, "utf8")) as StoredMeta) : null
  }

  private object(key: string, meta: StoredMeta, body?: ReadableStream<Uint8Array>, range?: { offset: number; length: number }): FsObject {
    return {
      key,
      size: meta.size,
      etag: meta.etag,
      httpEtag: `"${meta.etag}"`,
      uploaded: new Date(meta.uploaded),
      httpMetadata: meta.contentType ? { contentType: meta.contentType } : {},
      customMetadata: { ...meta.customMetadata },
      ...(range ? { range } : {}),
      ...(body ? { body } : {}),
      writeHttpMetadata: (h) => {
        if (meta.contentType) h.set("content-type", meta.contentType)
      }
    }
  }

  private multipartPath(uploadId: string) {
    return join(this.root, MULTIPART_DIR, checkUploadId(uploadId))
  }

  /**
   * An upload is its record `<id>.json` plus its own parts directory `<id>/`, so closing it touches
   * only its own parts. A stored part is `<id>/part.<n>`, with its etag in `<id>/part.<n>.json` once it is whole.
   */
  private partPath(uploadId: string, partNumber: number) {
    return join(this.multipartPath(uploadId), `part.${partNumber}`)
  }

  private multipartMetaPath(uploadId: string) {
    return `${this.multipartPath(uploadId)}.json`
  }

  /** The open upload `uploadId`, only when it was minted for `key`; R2 answers NoSuchUpload otherwise. */
  private readMultipart(key: string, uploadId: string): MultipartMeta | null {
    this.path(key)
    const path = this.multipartMetaPath(uploadId)
    if (!existsSync(path)) return null
    const meta = JSON.parse(readFileSync(path, "utf8")) as MultipartMeta
    if (meta.key !== key) throw noSuchUpload()
    return meta
  }

  private openMultipart(key: string, uploadId: string): MultipartMeta {
    const meta = this.readMultipart(key, uploadId)
    if (!meta) throw noSuchUpload()
    return meta
  }

  async put(key: string, value: unknown, options: ObjectOptions & { onlyIf?: { etagDoesNotMatch?: string } } = {}): Promise<FsObject | null> {
    const file = this.path(key)
    if (options.onlyIf?.etagDoesNotMatch === "*" && existsSync(file)) return null
    mkdirSync(dirname(file), { recursive: true })
    const tmp = `${file}.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`
    let stored: { etag: string; size: number }
    try { stored = await writeStream(tmp, bodyStream(value)) } catch (error) {
      rmSync(tmp, { force: true })
      throw error
    }
    const meta: StoredMeta = { ...stored, ...metadataOf(options), uploaded: Date.now() }
    renameSync(tmp, file)
    writeFileSync(`${file}.meta.json`, JSON.stringify(meta))
    return this.object(key, meta)
  }

  async createMultipartUpload(key: string, options: ObjectOptions = {}): Promise<FsMultipartUpload> {
    this.path(key)
    const uploadId = Array.from(randomBytes(16), (byte) => byte.toString(16).padStart(2, "0")).join("")
    mkdirSync(join(this.root, MULTIPART_DIR), { recursive: true })
    writeFileSync(this.multipartMetaPath(uploadId), JSON.stringify({ key, ...metadataOf(options) } satisfies MultipartMeta))
    return new FsMultipartUpload(this, uploadId, key)
  }

  resumeMultipartUpload(key: string, uploadId: string): FsMultipartUpload {
    this.path(key)
    checkUploadId(uploadId)
    return new FsMultipartUpload(this, uploadId, key)
  }

  async completeMultipart(key: string, uploadId: string, uploadedParts: Array<{ partNumber: number; etag: string }>): Promise<FsObject> {
    const meta = this.openMultipart(key, uploadId)
    // Check the whole list before writing a byte, as R2 does: ascending part numbers with no
    // repeats (InvalidPartOrder), each naming a part this upload stored, with its etag (InvalidPart).
    if (!Array.isArray(uploadedParts) || uploadedParts.length === 0) throw new FsBucketError("InvalidPart", "the parts list is empty")
    let previous = 0
    for (const part of uploadedParts) {
      if (!isPartNumber(part?.partNumber)) throw new FsBucketError("InvalidPart", "a part number must be an integer from 1 to 10,000")
      if (part.partNumber <= previous) throw new FsBucketError("InvalidPartOrder", "the parts list must be in ascending order by part number, without repeats")
      previous = part.partNumber
      const record = `${this.partPath(uploadId, part.partNumber)}.json`
      const stored = existsSync(record) ? (JSON.parse(readFileSync(record, "utf8")) as { etag: string }) : null
      if (!stored || typeof part.etag !== "string" || part.etag.replace(/"/g, "") !== stored.etag) throw new FsBucketError("InvalidPart", `part ${part.partNumber} was not stored, or its etag does not match`)
    }
    const output = this.path(meta.key)
    mkdirSync(dirname(output), { recursive: true })
    const tmp = `${output}.multipart-${process.pid}-${Math.random().toString(36).slice(2)}`
    const target = await open(tmp, "w")
    const hash = createHash("md5")
    let size = 0
    try {
      for (const part of uploadedParts) {
        const partPath = this.partPath(uploadId, part.partNumber)
        if (!existsSync(partPath)) throw new FsBucketError("InvalidPart", `part ${part.partNumber} was not stored`)
        const expected = part.etag.replace(/"/g, "")
        const partHash = createHash("md5")
        for await (const chunk of createReadStream(partPath)) {
          partHash.update(chunk)
          hash.update(chunk)
          for (let offset = 0; offset < chunk.byteLength;) {
            const { bytesWritten } = await target.write(chunk.subarray(offset))
            if (bytesWritten === 0) throw new Error("filesystem write made no progress")
            offset += bytesWritten
          }
          size += chunk.byteLength
        }
        if (partHash.digest("hex") !== expected) throw new FsBucketError("InvalidPart", `part ${part.partNumber} changed after it was stored`)
      }
      await target.close()
      renameSync(tmp, output)
    } catch (error) {
      await target.close().catch(() => undefined)
      rmSync(tmp, { force: true })
      throw error
    }
    const etag = hash.digest("hex")
    // The object keeps the upload's metadata, as R2 does (a caller recognises its own completed upload by it).
    const stored: StoredMeta = { etag, size, ...(meta.contentType ? { contentType: meta.contentType } : {}), ...(meta.customMetadata ? { customMetadata: meta.customMetadata } : {}), uploaded: Date.now() }
    writeFileSync(`${output}.meta.json`, JSON.stringify(stored))
    await this.abortMultipart(key, uploadId)
    return this.object(meta.key, stored)
  }

  async uploadMultipartPart(key: string, uploadId: string, partNumber: number, value: unknown): Promise<{ partNumber: number; etag: string }> {
    // The upload first, as R2 does: a forged, crossed or closed upload is NoSuchUpload whatever the number.
    this.openMultipart(key, uploadId)
    if (!isPartNumber(partNumber)) throw new FsBucketError("InvalidPart", "a part number must be an integer from 1 to 10,000")
    const partPath = this.partPath(uploadId, partNumber)
    // The part streams to a temp file and replaces any earlier upload of that number only once
    // whole; its etag record is written last, so completion never trusts a half-written part.
    const tmp = `${partPath}.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`
    mkdirSync(dirname(partPath), { recursive: true })
    try {
      const { etag, size } = await writeStream(tmp, bodyStream(value))
      rmSync(`${partPath}.json`, { force: true })
      renameSync(tmp, partPath)
      writeFileSync(`${partPath}.json`, JSON.stringify({ etag, size }))
      return { partNumber, etag }
    } catch (error) {
      rmSync(tmp, { force: true })
      throw error
    }
  }

  /** Aborting an upload that already closed is a no-op; one minted for another key is refused. */
  async abortMultipart(key: string, uploadId: string): Promise<void> {
    if (!this.readMultipart(key, uploadId)) return
    // Parts first, then the record, so a crash midway leaves an upload that can still be aborted.
    rmSync(this.multipartPath(uploadId), { recursive: true, force: true })
    rmSync(this.multipartMetaPath(uploadId), { force: true })
  }

  /**
   * Aborts every open upload whose key starts with `prefix`; answers how many. R2 ends abandoned
   * uploads by a bucket lifecycle rule and its binding cannot list them; this bucket has no
   * lifecycle, so the owner calls this when it deletes a conversation's storage, and an upload no
   * slot names (a lost slot, a failed expiry abort) does not stay on disk. Streams the directory:
   * memory stays bounded whatever the number of open uploads.
   */
  async abortMultipartUploads(prefix: string): Promise<number> {
    const dir = join(this.root, MULTIPART_DIR)
    if (!existsSync(dir)) return 0
    let aborted = 0
    for await (const entry of await opendir(dir)) {
      const id = /^([0-9a-f]{32})\.json$/.exec(entry.name)?.[1]
      if (!entry.isFile() || !id) continue
      const record = this.multipartMetaPath(id)
      let meta: MultipartMeta
      try {
        meta = JSON.parse(readFileSync(record, "utf8")) as MultipartMeta
      } catch (error) {
        // Closed by another request since the directory was read.
        if ((error as NodeJS.ErrnoException).code === "ENOENT") continue
        throw error
      }
      if (typeof meta.key !== "string" || !meta.key.startsWith(prefix)) continue
      await this.abortMultipart(meta.key, id)
      aborted++
    }
    return aborted
  }

  async head(key: string): Promise<FsObject | null> {
    const meta = this.meta(key)
    return meta ? this.object(key, meta) : null
  }

  async get(key: string, options: { range?: { offset?: number; length?: number; suffix?: number }; onlyIf?: { etagMatches?: string } } = {}): Promise<FsObject | null> {
    const meta = this.meta(key)
    if (!meta) return null
    // A failed precondition answers the object without a body, as R2 does.
    if (options.onlyIf?.etagMatches && options.onlyIf.etagMatches.replace(/"/g, "") !== meta.etag) return this.object(key, meta)
    let offset = 0
    let length = meta.size
    if (options.range) {
      if (options.range.suffix !== undefined) [offset, length] = [Math.max(0, meta.size - options.range.suffix), Math.min(options.range.suffix, meta.size)]
      else {
        offset = options.range.offset ?? 0
        length = options.range.length ?? meta.size - offset
      }
    }
    length = Math.max(0, Math.min(length, meta.size - offset))
    const body = Bun.file(this.path(key)).slice(offset, offset + length).stream()
    return this.object(key, meta, body, options.range ? { offset, length } : undefined)
  }

  async delete(keys: string | ReadonlyArray<string>): Promise<void> {
    for (const k of typeof keys === "string" ? [keys] : keys) {
      const file = this.path(k)
      rmSync(file, { force: true })
      rmSync(`${file}.meta.json`, { force: true })
    }
  }

  async list(options: { prefix?: string; limit?: number; cursor?: string } = {}): Promise<{ objects: Array<FsObject>; truncated: boolean; cursor?: string; delimitedPrefixes: Array<string> }> {
    const out: Array<FsObject> = []
    const walk = (dir: string) => {
      if (!existsSync(dir)) return
      for (const name of readdirSync(dir)) {
        // Open uploads and their parts are not objects; skip the directory rather than walk it.
        if (dir === this.root && name === MULTIPART_DIR) continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) walk(p)
        else if (!name.endsWith(".meta.json") && !name.includes(".tmp-")) {
          const key = relative(this.root, p).split(sep).join("/")
          // A file no key could have written (a backslash in its name, say) is not an object.
          if (!isKey(this.root, key)) continue
          const meta = this.meta(key)
          if (meta && (!options.prefix || key.startsWith(options.prefix))) out.push(this.object(key, meta))
        }
      }
    }
    walk(this.root)
    out.sort((a, b) => (a.key < b.key ? -1 : 1))
    const start = options.cursor ? out.findIndex((object) => object.key > options.cursor!) : 0
    if (start < 0) return { objects: [], truncated: false, delimitedPrefixes: [] }
    const limit = options.limit ?? 1000
    const page = out.slice(start, start + limit)
    const truncated = start + limit < out.length
    return { objects: page, truncated, ...(truncated ? { cursor: page.at(-1)!.key } : {}), delimitedPrefixes: [] }
  }
}

/** R2 multipart handle backed by bounded files under `.multipart`. */
export class FsMultipartUpload {
  constructor(private readonly bucket: FsBucket, readonly uploadId: string, readonly key: string) {}

  async uploadPart(partNumber: number, value: ReadableStream | ArrayBuffer | ArrayBufferView | string | Blob): Promise<{ partNumber: number; etag: string }> {
    return this.bucket.uploadMultipartPart(this.key, this.uploadId, partNumber, value)
  }

  async abort(): Promise<void> {
    await this.bucket.abortMultipart(this.key, this.uploadId)
  }

  async complete(uploadedParts: Array<{ partNumber: number; etag: string }>): Promise<FsObject> {
    return this.bucket.completeMultipart(this.key, this.uploadId, uploadedParts)
  }
}

/**
 * Workers' `FixedLengthStream`: an identity stream that fails when the bytes written are not
 * exactly `length` (home-attachment-stream.ts pipes uploads through one).
 */
export class FixedLengthStream extends TransformStream<Uint8Array, Uint8Array> {
  constructor(length: number | bigint) {
    const want = Number(length)
    let seen = 0
    super({
      transform(chunk, ctl) {
        seen += chunk.byteLength
        if (seen > want) return ctl.error(new Error("FixedLengthStream: too many bytes"))
        ctl.enqueue(chunk)
      },
      flush(ctl) {
        if (seen !== want) ctl.error(new Error("FixedLengthStream: too few bytes"))
      }
    })
  }
}
