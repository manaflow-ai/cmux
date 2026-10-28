import { createHash, randomBytes } from "node:crypto"
import { createReadStream, existsSync, linkSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs"
import { open } from "node:fs/promises"
import { dirname, join, relative, sep } from "node:path"

/** What the attachment code reads back from a stored object (the R2 subset it uses). */
interface StoredMeta {
  readonly etag: string
  readonly size: number
  readonly contentType?: string
  readonly uploaded: number
}

interface MultipartMeta {
  readonly key: string
  readonly contentType?: string
}

/** A stored object as R2 returns it, with a body when it was a `get`. */
export interface FsObject {
  readonly key: string
  readonly size: number
  readonly etag: string
  readonly httpEtag: string
  readonly uploaded: Date
  readonly httpMetadata: { contentType?: string }
  readonly range?: { offset: number; length: number }
  readonly body?: ReadableStream<Uint8Array>
  writeHttpMetadata(headers: Headers): void
}

/** Keys are paths under the root; `..` and absolute paths are refused. */
const safeKey = (key: string) => {
  if (!key || key.startsWith("/") || key.split("/").some((p) => p === ".." || p === "")) throw new Error("invalid object key")
  return key
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
    return join(this.root, safeKey(key))
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
      ...(range ? { range } : {}),
      ...(body ? { body } : {}),
      writeHttpMetadata: (h) => {
        if (meta.contentType) h.set("content-type", meta.contentType)
      }
    }
  }

  private multipartPath(uploadId: string) {
    safeKey(uploadId)
    return join(this.root, ".multipart", uploadId)
  }

  private multipartMetaPath(uploadId: string) {
    return `${this.multipartPath(uploadId)}.json`
  }

  readMultipart(uploadId: string): MultipartMeta {
    const path = this.multipartMetaPath(uploadId)
    if (!existsSync(path)) throw new Error("multipart upload is missing or already closed")
    return JSON.parse(readFileSync(path, "utf8")) as MultipartMeta
  }

  async put(key: string, value: unknown, options: { httpMetadata?: { contentType?: string }; onlyIf?: { etagDoesNotMatch?: string } } = {}): Promise<FsObject | null> {
    const file = this.path(key)
    if (options.onlyIf?.etagDoesNotMatch === "*" && existsSync(file)) return null
    mkdirSync(dirname(file), { recursive: true })
    const tmp = `${file}.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`
    let stored: { etag: string; size: number }
    try { stored = await writeStream(tmp, bodyStream(value)) } catch (error) {
      rmSync(tmp, { force: true })
      throw error
    }
    const meta: StoredMeta = { ...stored, ...(options.httpMetadata?.contentType ? { contentType: options.httpMetadata.contentType } : {}), uploaded: Date.now() }
    if (options.onlyIf?.etagDoesNotMatch === "*") {
      // Link is an atomic create: unlike HEAD-then-rename, two concurrent
      // writers cannot both win this conditional put.
      try { linkSync(tmp, file) } catch (error) {
        rmSync(tmp, { force: true })
        if ((error as NodeJS.ErrnoException).code === "EEXIST") return null
        throw error
      }
      rmSync(tmp, { force: true })
    } else renameSync(tmp, file)
    writeFileSync(`${file}.meta.json`, JSON.stringify(meta))
    return this.object(key, meta)
  }

  async createMultipartUpload(key: string, options: { httpMetadata?: { contentType?: string } } = {}): Promise<FsMultipartUpload> {
    safeKey(key)
    const uploadId = Array.from(randomBytes(16), (byte) => byte.toString(16).padStart(2, "0")).join("")
    mkdirSync(join(this.root, ".multipart"), { recursive: true })
    writeFileSync(this.multipartMetaPath(uploadId), JSON.stringify({ key, ...(options.httpMetadata?.contentType ? { contentType: options.httpMetadata.contentType } : {}) } satisfies MultipartMeta))
    return new FsMultipartUpload(this, uploadId, key)
  }

  resumeMultipartUpload(key: string, uploadId: string): FsMultipartUpload {
    safeKey(key)
    return new FsMultipartUpload(this, uploadId, key)
  }

  async completeMultipart(uploadId: string, uploadedParts: Array<{ partNumber: number; etag: string }>): Promise<FsObject> {
    const meta = this.readMultipart(uploadId)
    const output = this.path(meta.key)
    mkdirSync(dirname(output), { recursive: true })
    const tmp = `${output}.multipart-${process.pid}-${Math.random().toString(36).slice(2)}`
    const target = await open(tmp, "w")
    const hash = createHash("md5")
    let size = 0
    try {
      for (const part of uploadedParts) {
        const partPath = this.multipartPath(uploadId) + `.part.${part.partNumber}`
        if (!existsSync(partPath)) throw new Error("multipart part is missing")
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
        if (partHash.digest("hex") !== expected) throw new Error("multipart part etag mismatch")
      }
      await target.close()
      renameSync(tmp, output)
    } catch (error) {
      await target.close().catch(() => undefined)
      rmSync(tmp, { force: true })
      throw error
    }
    const etag = hash.digest("hex")
    const stored: StoredMeta = { etag, size, ...(meta.contentType ? { contentType: meta.contentType } : {}), uploaded: Date.now() }
    writeFileSync(`${output}.meta.json`, JSON.stringify(stored))
    await this.abortMultipart(uploadId)
    return this.object(meta.key, stored)
  }

  async uploadMultipartPart(uploadId: string, partNumber: number, value: unknown): Promise<{ partNumber: number; etag: string }> {
    if (!Number.isSafeInteger(partNumber) || partNumber <= 0) throw new Error("invalid multipart part")
    this.readMultipart(uploadId)
    const partPath = this.multipartPath(uploadId) + `.part.${partNumber}`
    try {
      const { etag } = await writeStream(partPath, bodyStream(value))
      return { partNumber, etag }
    } catch (error) {
      rmSync(partPath, { force: true })
      throw error
    }
  }

  async abortMultipart(uploadId: string): Promise<void> {
    const dir = join(this.root, ".multipart")
    rmSync(this.multipartMetaPath(uploadId), { force: true })
    if (existsSync(dir)) for (const name of readdirSync(dir, { withFileTypes: true })) {
      if (name.isFile() && name.name.startsWith(uploadId + ".part.")) rmSync(join(dir, name.name), { force: true })
    }
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
        const p = join(dir, name)
        if (statSync(p).isDirectory()) walk(p)
        else if (!name.endsWith(".meta.json") && !name.includes(".tmp-")) {
          const key = relative(this.root, p).split(sep).join("/")
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
    return this.bucket.uploadMultipartPart(this.uploadId, partNumber, value)
  }

  async abort(): Promise<void> {
    await this.bucket.abortMultipart(this.uploadId)
  }

  async complete(uploadedParts: Array<{ partNumber: number; etag: string }>): Promise<FsObject> {
    return this.bucket.completeMultipart(this.uploadId, uploadedParts)
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
