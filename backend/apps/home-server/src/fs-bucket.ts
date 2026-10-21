import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs"
import { dirname, join, relative, sep } from "node:path"

/** What the attachment code reads back from a stored object (the R2 subset it uses). */
interface StoredMeta {
  readonly etag: string
  readonly size: number
  readonly contentType?: string
  readonly uploaded: number
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

const toBytes = async (value: unknown): Promise<Uint8Array> => {
  if (value === null || value === undefined) return new Uint8Array()
  if (typeof value === "string") return new TextEncoder().encode(value)
  if (value instanceof ArrayBuffer) return new Uint8Array(value)
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
  if (value instanceof ReadableStream) return new Uint8Array(await new Response(value).arrayBuffer())
  if (value instanceof Blob) return new Uint8Array(await value.arrayBuffer())
  throw new TypeError("unsupported object body")
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

  async put(key: string, value: unknown, options: { httpMetadata?: { contentType?: string }; onlyIf?: { etagDoesNotMatch?: string } } = {}): Promise<FsObject | null> {
    const file = this.path(key)
    if (options.onlyIf?.etagDoesNotMatch === "*" && existsSync(file)) return null
    const bytes = await toBytes(value)
    mkdirSync(dirname(file), { recursive: true })
    const etag = createHash("md5").update(bytes).digest("hex")
    const meta: StoredMeta = { etag, size: bytes.byteLength, ...(options.httpMetadata?.contentType ? { contentType: options.httpMetadata.contentType } : {}), uploaded: Date.now() }
    const tmp = `${file}.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`
    writeFileSync(tmp, bytes)
    renameSync(tmp, file)
    writeFileSync(`${file}.meta.json`, JSON.stringify(meta))
    return this.object(key, meta)
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
    const bytes = readFileSync(this.path(key))
    let offset = 0
    let length = bytes.byteLength
    if (options.range) {
      if (options.range.suffix !== undefined) [offset, length] = [Math.max(0, bytes.byteLength - options.range.suffix), Math.min(options.range.suffix, bytes.byteLength)]
      else {
        offset = options.range.offset ?? 0
        length = options.range.length ?? bytes.byteLength - offset
      }
    }
    const slice = bytes.subarray(offset, offset + length)
    return this.object(key, meta, new Blob([slice]).stream(), options.range ? { offset, length: slice.byteLength } : undefined)
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
    const start = options.cursor ? Number(options.cursor) : 0
    const limit = options.limit ?? 1000
    const page = out.slice(start, start + limit)
    const truncated = start + limit < out.length
    return { objects: page, truncated, ...(truncated ? { cursor: String(start + limit) } : {}), delimitedPrefixes: [] }
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
