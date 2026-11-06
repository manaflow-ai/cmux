import { createHash, randomBytes } from "node:crypto"
import { closeSync, constants, createReadStream, fstatSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, realpathSync, renameSync, rmSync, statSync } from "node:fs"
import type { Stats } from "node:fs"
import { open, opendir } from "node:fs/promises"
import type { FileHandle } from "node:fs/promises"
import { basename, dirname, isAbsolute, join, posix, relative, resolve, sep } from "node:path"
import { Readable } from "node:stream"

/** What the attachment code reads back from a stored object (the R2 subset it uses). */
interface StoredMeta {
  readonly etag: string
  /** The digest of the bytes, separate from the HTTP-facing etag so torn commits are detectable. */
  readonly contentHash: string
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
 * A name as a case- and normalization-insensitive filesystem may compare it (APFS, HFS+, NTFS):
 * default-ignorable code points dropped (HFS+ ignores some), NFKC, case folded through upper then
 * lower case, NFKC again, and trailing dots and spaces dropped (Windows strips them). NFKC rather
 * than NFC so compatibility lookalikes (fullwidth "．ｍｕｌｔｉｐａｒｔ") fold too: this folds more
 * than any of those filesystems does, so it refuses at least every name that aliases, never fewer.
 */
const fold = (name: string) =>
  name
    .replace(/\p{Default_Ignorable_Code_Point}/gu, "")
    .normalize("NFKC")
    .toUpperCase()
    .toLowerCase()
    .normalize("NFKC")
    .replace(/[. ]+$/u, "")

/** The first segment that names the internal multipart directory, in any case or form. */
const isReserved = (segment: string) => fold(segment) === MULTIPART_DIR

/**
 * The one way a key becomes a path. A key is "/"-separated segments, none of them empty, "." or
 * "..", with no backslash, NUL or leading "/"; its normalized form must be itself, must resolve
 * strictly inside `root`, and its first segment must not fold to the internal multipart directory
 * (an inner `.multipart` segment is an ordinary name).
 */
const keyPath = (root: string, key: string): string => {
  if (typeof key !== "string" || key === "" || key.startsWith("/") || /[\\\0]/.test(key)) throw invalidKey()
  if (key.split("/").some((p) => p === "" || p === "." || p === "..")) throw invalidKey()
  const normalized = posix.normalize(key)
  if (normalized !== key || isAbsolute(normalized) || isReserved(normalized.split("/")[0]!)) throw invalidKey()
  const inside = relative(resolve(root), resolve(root, normalized))
  if (!inside || inside === ".." || inside.startsWith(`..${sep}`) || isAbsolute(inside) || isReserved(inside.split(sep)[0]!)) throw invalidKey()
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
  constructor(readonly code: "NoSuchUpload" | "InvalidPart" | "InvalidPartOrder" | "InvalidMaxKeys", message: string) {
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

const linkError = () => new Error("object path crosses a symbolic link")

const errorCode = (error: unknown) => (error as NodeJS.ErrnoException | null)?.code

/** What sits at `path` without following a link, or null when nothing does. */
const lstatOrNull = (path: string): Stats | null => {
  try {
    return lstatSync(path)
  } catch (error) {
    if (errorCode(error) === "ENOENT" || errorCode(error) === "ENOTDIR") return null
    throw error
  }
}

/** `path` as a real directory, made if missing; a link there is refused. */
const ensureDir = (path: string) => {
  try {
    mkdirSync(path)
  } catch (error) {
    if (errorCode(error) !== "EEXIST") throw error
  }
  const stat = lstatSync(path)
  if (stat.isSymbolicLink()) throw linkError()
  if (!stat.isDirectory()) throw new Error(`not a directory: ${path}`)
}

/** Opens a file itself, never a link's target; null when it does not exist. */
const openNoFollow = (path: string): number | null => {
  try {
    return openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW)
  } catch (error) {
    if (errorCode(error) === "ENOENT" || errorCode(error) === "ENOTDIR") return null
    if (errorCode(error) === "ELOOP") throw linkError()
    throw error
  }
}

/** A fresh temp file: created here (never an existing file or link), not followed. */
const CREATE_NEW = constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW

const tempName = (path: string) => `${path}.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`

/** Bytes `[start, start + length)` of an open file as a stream that closes the file when done. */
const fileStream = (fd: number, start: number, length: number): ReadableStream<Uint8Array> => {
  if (length <= 0) {
    closeSync(fd)
    return new Blob().stream()
  }
  return Readable.toWeb(createReadStream("", { fd, start, end: start + length - 1 })) as unknown as ReadableStream<Uint8Array>
}

const bodyStream = (value: unknown): ReadableStream<Uint8Array> => {
  if (value instanceof ReadableStream) return value
  if (value instanceof Blob) return value.stream()
  if (value === null || value === undefined) return new Blob().stream()
  if (typeof value === "string" || value instanceof ArrayBuffer) return new Blob([value]).stream()
  if (ArrayBuffer.isView(value)) return new Blob([new Uint8Array(new Uint8Array(value.buffer, value.byteOffset, value.byteLength))]).stream()
  throw new TypeError("unsupported object body")
}

/** Where a path may land: an object's place in the key space, or the bucket's own upload directory. */
type Area = "key" | "upload"

export interface FsBucketOptions {
  /** Test seam only: runs after the bucket has checked a path's directories and before it uses them. */
  readonly afterPathCheck?: (path: string) => void
}

/**
 * The R2 bucket subset the Home attachment code uses (`put`, `get` with range and etag match,
 * `head`, `delete`, `list` by prefix), as files under `root`. Each object is `<key>` plus
 * `<key>.meta.json`; a put writes a temp file and renames it, so a reader never sees half a file.
 *
 * Nothing in the bucket is reached through a symbolic link. The root is resolved once. Each
 * directory between it and a file is checked with lstat (one call per segment, no walk). Node and
 * Bun have no openat, so a checked directory is then used by name and could be swapped for a link
 * before it is used; every use is re-checked where it really lands:
 * - a file is opened with O_NOFOLLOW (new files also O_EXCL), then its realpath must be inside the
 *   root, in the area the caller expects, and name the same inode as the open descriptor;
 * - a directory is realpath-checked after put makes it, and right before a file is created in it,
 *   renamed into it or removed from it.
 * Residual window: a swap after that last check and before the rename, unlink or mkdir itself.
 * Closing it needs renameat/unlinkat/mkdirat on a held directory descriptor, which Node lacks.
 */
export class FsBucket {
  private readonly root: string
  private readonly uploadLocks = new Map<string, Promise<void>>()

  /** A configured root that is itself a link is fine: it is resolved once, here. */
  constructor(root: string, private readonly options: FsBucketOptions = {}) {
    mkdirSync(root, { recursive: true })
    this.root = realpathSync(root)
  }

  /** Serialize all mutations of one multipart upload, including awaits while streaming bytes. */
  private async withUploadLock<T>(uploadId: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.uploadLocks.get(uploadId) ?? Promise.resolve()
    let release!: () => void
    const next = new Promise<void>((resolve) => { release = resolve })
    this.uploadLocks.set(uploadId, next)
    await previous
    try {
      return await operation()
    } finally {
      release()
      if (this.uploadLocks.get(uploadId) === next) this.uploadLocks.delete(uploadId)
    }
  }

  /** `real` must be under the root: in the key space (the root itself included) or in `.multipart`. */
  private inside(real: string, area: Area) {
    const rel = relative(this.root, real)
    if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) throw linkError()
    const first = rel.split(sep)[0]!
    if (area === "upload" ? first !== MULTIPART_DIR : rel !== "" && isReserved(first)) throw linkError()
  }

  private realpath(path: string) {
    try {
      return realpathSync(path)
    } catch (error) {
      // Gone or looping since it was checked: it was swapped.
      if (errorCode(error) === "ENOENT" || errorCode(error) === "ENOTDIR" || errorCode(error) === "ELOOP") throw linkError()
      throw error
    }
  }

  private checkDir(dir: string, area: Area) {
    this.inside(this.realpath(dir), area)
  }

  /** The open descriptor is the file `path` names inside the bucket, not one reached through a swapped directory. */
  private checkFd(fd: number, path: string, area: Area) {
    const real = this.realpath(path)
    this.inside(real, area)
    const opened = fstatSync(fd, { bigint: true })
    const named = statSync(real, { bigint: true })
    if (opened.dev !== named.dev || opened.ino !== named.ino) throw linkError()
  }

  private openFile(path: string, area: Area): number | null {
    const fd = openNoFollow(path)
    if (fd === null) return null
    try {
      this.checkFd(fd, path, area)
    } catch (error) {
      closeSync(fd)
      throw error
    }
    return fd
  }

  private readJson<T>(path: string, area: Area): T | null {
    const fd = this.openFile(path, area)
    if (fd === null) return null
    try {
      return JSON.parse(readFileSync(fd, "utf8")) as T
    } finally {
      closeSync(fd)
    }
  }

  /** A new file at `path` whose descriptor was checked; one that landed elsewhere is removed only if `path` still names it. */
  private async createFile(path: string, area: Area): Promise<FileHandle> {
    this.checkDir(dirname(path), area)
    const file = await open(path, CREATE_NEW, 0o644)
    try {
      this.checkFd(file.fd, path, area)
    } catch (error) {
      const made = fstatSync(file.fd, { bigint: true })
      const named = lstatOrNull(path)
      if (named && BigInt(named.ino) === made.ino && BigInt(named.dev) === made.dev) rmSync(path, { force: true })
      await file.close()
      throw error
    }
    return file
  }

  /** Writes `path` by renaming a fresh temp file over it; a link at `path` is replaced, not followed. */
  /** Writes `data` to a fresh temp file beside `path`; answers the temp file, for the caller to rename. */
  private async stage(path: string, data: string, area: Area): Promise<string> {
    const tmp = tempName(path)
    const file = await this.createFile(tmp, area)
    try {
      await file.writeFile(data)
    } catch (error) {
      await file.close()
      rmSync(tmp, { force: true })
      throw error
    }
    await file.close()
    return tmp
  }

  private async writeFile(path: string, data: string, area: Area) {
    this.rename(await this.stage(path, data, area), path, area)
  }

  /**
   * Makes the staged `dataTmp` and `metaTmp` the object at `file`, in one synchronous step. The
   * home-server process is this bucket's only writer, and a step with no await runs whole in it: no
   * other put, completion, delete or read of the key runs in between, so the last commit wins
   * whole and a reader never pairs one write's bytes with another's metadata. With `onlyIfAbsent`,
   * an object already at `file` (one committed while this write streamed, too) wins and nothing is
   * renamed. Data is published first and metadata last; the metadata carries a content hash, so a
   * crash between the two renames is always rejected by metaAt, including equal-sized overwrites.
   */
  private commit(file: string, dataTmp: string, metaTmp: string, onlyIfAbsent = false): boolean {
    if (onlyIfAbsent && lstatOrNull(file)) return false
    this.rename(dataTmp, file, "key")
    this.rename(metaTmp, `${file}.meta.json`, "key")
    return true
  }

  private rename(from: string, to: string, area: Area) {
    const dir = dirname(to)
    if (dirname(from) !== dir) throw new Error("bucket rename must stay in one directory")
    // Node has no renameat wrapper, so hold the checked directory and address both names through
    // its descriptor. A path-based rename can follow a parent that an actor swaps after checkDir.
    this.checkDir(dir, area)
    this.options.afterPathCheck?.(to)
    let directory: number
    try {
      directory = openSync(dir, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW)
    } catch (error) {
      if (["ELOOP", "ENOTDIR", "ENOENT"].includes(errorCode(error) ?? "")) throw linkError()
      throw error
    }
    try {
      this.checkFd(directory, dir, area)
      const fdPath = process.platform === "linux" ? `/proc/self/fd/${directory}` : `/dev/fd/${directory}`
      renameSync(join(fdPath, basename(from)), join(fdPath, basename(to)))
    } finally {
      closeSync(directory)
    }
  }

  /** Remove through a held parent descriptor, so a checked directory cannot be swapped to a link. */
  private remove(path: string, area: Area, recursive = false) {
    const dir = dirname(path)
    this.checkDir(dir, area)
    this.options.afterPathCheck?.(path)
    let directory: number
    try {
      directory = openSync(dir, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW)
    } catch (error) {
      if (["ELOOP", "ENOTDIR", "ENOENT"].includes(errorCode(error) ?? "")) throw linkError()
      throw error
    }
    try {
      this.checkFd(directory, dir, area)
      const fdPath = process.platform === "linux" ? `/proc/self/fd/${directory}` : `/dev/fd/${directory}`
      rmSync(join(fdPath, basename(path)), { force: true, recursive })
    } finally {
      closeSync(directory)
    }
  }

  /** Drain to disk with bounded memory, including short filesystem writes. */
  private async writeStream(path: string, stream: ReadableStream<Uint8Array>, area: Area): Promise<{ etag: string; size: number }> {
    const file = await this.createFile(path, area)
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
   * The file for `key`, after checking each directory between the root and it: a link there is
   * refused, and a missing one (or a file in its place) answers null, as nothing is stored below it.
   * With `create`, missing directories are made one at a time, each checked as it is made, and the
   * last one's real path is checked once they all exist.
   */
  private path(key: string, create = false): string | null {
    const file = keyPath(this.root, key)
    let dir = this.root
    for (const segment of key.split("/").slice(0, -1)) {
      dir = join(dir, segment)
      if (create) {
        ensureDir(dir)
        continue
      }
      const stat = lstatOrNull(dir)
      if (stat?.isSymbolicLink()) throw linkError()
      if (!stat?.isDirectory()) return null
    }
    this.options.afterPathCheck?.(file)
    if (create) this.checkDir(dir, "key")
    return file
  }

  /** An object's metadata; the object file itself must not be a link either. */
  private metaAt(file: string): StoredMeta | null {
    const meta = this.readJson<StoredMeta>(`${file}.meta.json`, "key")
    if (!meta) return null
    const fd = this.openFile(file, "key")
    if (fd === null) return null
    try {
      if (typeof meta.etag !== "string") return null
      const stat = fstatSync(fd)
      if (!stat.isFile() || stat.size !== meta.size) return null
      // Hash in bounded chunks. A crash between the data and metadata renames, or an equal-sized
      // overwrite, must never serve bytes under a stale etag.
      const hash = createHash("md5")
      const buffer = Buffer.allocUnsafe(64 * 1024)
      let offset = 0
      while (offset < stat.size) {
        const count = readSync(fd, buffer, 0, Math.min(buffer.byteLength, stat.size - offset), offset)
        if (count === 0) return null
        hash.update(buffer.subarray(0, count))
        offset += count
      }
      const digest = hash.digest("hex")
      if (digest !== meta.etag) return null
      // Accept sidecars written before contentHash was introduced. The verified etag is the
      // legacy content hash; new writes persist it explicitly for torn-commit detection.
      return typeof meta.contentHash === "string" && meta.contentHash !== meta.etag ? null : { ...meta, contentHash: meta.contentHash ?? meta.etag }
    } finally {
      closeSync(fd)
    }
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

  private get multipartDir() {
    return join(this.root, MULTIPART_DIR)
  }

  /** The upload's parts directory; `.multipart` and the parts directory must not be links. */
  private multipartPath(uploadId: string) {
    const path = join(this.multipartDir, checkUploadId(uploadId))
    if (lstatOrNull(this.multipartDir)?.isSymbolicLink() || lstatOrNull(path)?.isSymbolicLink()) throw linkError()
    this.options.afterPathCheck?.(path)
    return path
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
    keyPath(this.root, key)
    const meta = this.readJson<MultipartMeta>(this.multipartMetaPath(uploadId), "upload")
    if (!meta) return null
    if (meta.key !== key) throw noSuchUpload()
    return meta
  }

  private openMultipart(key: string, uploadId: string): MultipartMeta {
    const meta = this.readMultipart(key, uploadId)
    if (!meta) throw noSuchUpload()
    return meta
  }

  async put(key: string, value: unknown, options: ObjectOptions & { onlyIf?: { etagDoesNotMatch?: string } } = {}): Promise<FsObject | null> {
    const file = this.path(key, true)!
    if (options.onlyIf?.etagDoesNotMatch === "*" && lstatOrNull(file)) return null
    const tmp = tempName(file)
    let stored: { etag: string; size: number }
    try { stored = await this.writeStream(tmp, bodyStream(value), "key") } catch (error) {
      rmSync(tmp, { force: true })
      throw error
    }
    const meta: StoredMeta = { ...stored, contentHash: stored.etag, ...metadataOf(options), uploaded: Date.now() }
    let metaTmp: string | undefined
    try {
      metaTmp = await this.stage(`${file}.meta.json`, JSON.stringify(meta), "key")
      if (!this.commit(file, tmp, metaTmp, options.onlyIf?.etagDoesNotMatch === "*")) return null
    } finally {
      // Renamed into place on success; left over when the commit was refused or failed.
      rmSync(tmp, { force: true })
      if (metaTmp) rmSync(metaTmp, { force: true })
    }
    return this.object(key, meta)
  }

  async createMultipartUpload(key: string, options: ObjectOptions = {}): Promise<FsMultipartUpload> {
    this.path(key)
    const uploadId = Array.from(randomBytes(16), (byte) => byte.toString(16).padStart(2, "0")).join("")
    ensureDir(this.multipartDir)
    await this.writeFile(this.multipartMetaPath(uploadId), JSON.stringify({ key, ...metadataOf(options) } satisfies MultipartMeta), "upload")
    return new FsMultipartUpload(this, uploadId, key)
  }

  resumeMultipartUpload(key: string, uploadId: string): FsMultipartUpload {
    keyPath(this.root, key)
    checkUploadId(uploadId)
    // Validate the persisted record now, rather than returning a handle that can only
    // discover a missing or crossed key on its first operation.
    this.openMultipart(key, uploadId)
    return new FsMultipartUpload(this, uploadId, key)
  }

  async completeMultipart(key: string, uploadId: string, uploadedParts: Array<{ partNumber: number; etag: string }>): Promise<FsObject> {
    return this.withUploadLock(uploadId, () => this.completeMultipartUnlocked(key, uploadId, uploadedParts))
  }

  private async completeMultipartUnlocked(key: string, uploadId: string, uploadedParts: Array<{ partNumber: number; etag: string }>): Promise<FsObject> {
    const meta = this.openMultipart(key, uploadId)
    // Check the whole list before writing a byte, as R2 does: ascending part numbers with no
    // repeats (InvalidPartOrder), each naming a part this upload stored, with its etag (InvalidPart).
    if (!Array.isArray(uploadedParts) || uploadedParts.length === 0) throw new FsBucketError("InvalidPart", "the parts list is empty")
    let previous = 0
    for (const part of uploadedParts) {
      if (!isPartNumber(part?.partNumber)) throw new FsBucketError("InvalidPart", "a part number must be an integer from 1 to 10,000")
      if (part.partNumber <= previous) throw new FsBucketError("InvalidPartOrder", "the parts list must be in ascending order by part number, without repeats")
      previous = part.partNumber
      const stored = this.readJson<{ etag: string }>(`${this.partPath(uploadId, part.partNumber)}.json`, "upload")
      if (!stored || typeof part.etag !== "string" || part.etag.replace(/"/g, "") !== stored.etag) throw new FsBucketError("InvalidPart", `part ${part.partNumber} was not stored, or its etag does not match`)
    }
    const output = this.path(meta.key, true)!
    const tmp = `${output}.multipart-${process.pid}-${Math.random().toString(36).slice(2)}`
    const target = await this.createFile(tmp, "key")
    const hash = createHash("md5")
    let size = 0
    try {
      for (const part of uploadedParts) {
        const partFd = this.openFile(this.partPath(uploadId, part.partNumber), "upload")
        if (partFd === null) throw new FsBucketError("InvalidPart", `part ${part.partNumber} was not stored`)
        const expected = part.etag.replace(/"/g, "")
        const partHash = createHash("md5")
        for await (const chunk of createReadStream("", { fd: partFd }) as AsyncIterable<Buffer>) {
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
    } catch (error) {
      await target.close().catch(() => undefined)
      rmSync(tmp, { force: true })
      throw error
    }
    const etag = hash.digest("hex")
    // The object keeps the upload's metadata, as R2 does (a caller recognises its own completed upload by it).
    const stored: StoredMeta = { etag, contentHash: etag, size, ...(meta.contentType ? { contentType: meta.contentType } : {}), ...(meta.customMetadata ? { customMetadata: meta.customMetadata } : {}), uploaded: Date.now() }
    let metaTmp: string | undefined
    try {
      metaTmp = await this.stage(`${output}.meta.json`, JSON.stringify(stored), "key")
      this.commit(output, tmp, metaTmp)
    } finally {
      rmSync(tmp, { force: true })
      if (metaTmp) rmSync(metaTmp, { force: true })
    }
    await this.abortMultipartUnlocked(key, uploadId)
    return this.object(meta.key, stored)
  }

  async uploadMultipartPart(key: string, uploadId: string, partNumber: number, value: unknown): Promise<{ partNumber: number; etag: string }> {
    return this.withUploadLock(uploadId, () => this.uploadMultipartPartUnlocked(key, uploadId, partNumber, value))
  }

  private async uploadMultipartPartUnlocked(key: string, uploadId: string, partNumber: number, value: unknown): Promise<{ partNumber: number; etag: string }> {
    // The upload first, as R2 does: a forged, crossed or closed upload is NoSuchUpload whatever the number.
    this.openMultipart(key, uploadId)
    if (!isPartNumber(partNumber)) throw new FsBucketError("InvalidPart", "a part number must be an integer from 1 to 10,000")
    const partsDir = this.multipartPath(uploadId)
    const partPath = join(partsDir, `part.${partNumber}`)
    // The part streams to a temp file and replaces any earlier upload of that number only once
    // whole; its etag record is written last, so completion never trusts a half-written part.
    this.checkDir(this.multipartDir, "upload")
    ensureDir(partsDir)
    const tmp = tempName(partPath)
    try {
      const { etag, size } = await this.writeStream(tmp, bodyStream(value), "upload")
      this.checkDir(partsDir, "upload")
      this.remove(`${partPath}.json`, "upload")
      this.rename(tmp, partPath, "upload")
      await this.writeFile(`${partPath}.json`, JSON.stringify({ etag, size }), "upload")
      return { partNumber, etag }
    } catch (error) {
      rmSync(tmp, { force: true })
      throw error
    }
  }

  /** Aborting an upload that already closed is a no-op; one minted for another key is refused. */
  async abortMultipart(key: string, uploadId: string): Promise<void> {
    return this.withUploadLock(uploadId, () => this.abortMultipartUnlocked(key, uploadId))
  }

  private async abortMultipartUnlocked(key: string, uploadId: string): Promise<void> {
    if (!this.readMultipart(key, uploadId)) return
    // Parts first, then the record, so a crash midway leaves an upload that can still be aborted.
    // rm never follows a link inside the tree it removes; the tree itself is checked first.
    const partsDir = this.multipartPath(uploadId)
    if (lstatOrNull(partsDir)) this.checkDir(partsDir, "upload")
    this.remove(partsDir, "upload", true)
    // Each path is named (and passes its lstat checks) before the directory it is in is checked, then used.
    const record = this.multipartMetaPath(uploadId)
    this.checkDir(this.multipartDir, "upload")
    this.remove(record, "upload")
  }

  /**
   * Aborts every open upload whose key starts with `prefix`; answers how many. R2 ends abandoned
   * uploads by a bucket lifecycle rule and its binding cannot list them; this bucket has no
   * lifecycle, so the owner calls this when it deletes a conversation's storage, and an upload no
   * slot names (a lost slot, a failed expiry abort) does not stay on disk. Streams the directory:
   * memory stays bounded whatever the number of open uploads.
   */
  async abortMultipartUploads(prefix: string): Promise<number> {
    const dir = this.multipartDir
    const stat = lstatOrNull(dir)
    if (!stat) return 0
    if (stat.isSymbolicLink()) throw linkError()
    const entries = await opendir(dir)
    // The directory opened is the bucket's own, unless it was swapped since the lstat: then refuse.
    // Every record read below is opened no-follow and realpath-checked inside .multipart, and every
    // abort re-checks the paths it removes, so a swap after this check reads or removes nothing outside.
    try {
      this.checkDir(dir, "upload")
    } catch (error) {
      await entries.close()
      throw error
    }
    let aborted = 0
    for await (const entry of entries) {
      // Only an upload's own record (a regular file, never a link); its key must still be a valid key.
      const id = /^([0-9a-f]{32})\.json$/.exec(entry.name)?.[1]
      if (!entry.isFile() || !id) continue
      // Null: closed by another request since the directory was read.
      const meta = this.readJson<MultipartMeta>(this.multipartMetaPath(id), "upload")
      if (!meta || typeof meta.key !== "string" || !meta.key.startsWith(prefix) || !isKey(this.root, meta.key)) continue
      await this.abortMultipart(meta.key, id)
      aborted++
    }
    return aborted
  }

  async head(key: string): Promise<FsObject | null> {
    const file = this.path(key)
    const meta = file === null ? null : this.metaAt(file)
    return meta ? this.object(key, meta) : null
  }

  async get(key: string, options: { range?: { offset?: number; length?: number; suffix?: number }; onlyIf?: { etagMatches?: string } } = {}): Promise<FsObject | null> {
    const file = this.path(key)
    if (file === null) return null
    const meta = this.metaAt(file)
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
    const fd = this.openFile(file, "key")
    if (fd === null) return null
    const body = fileStream(fd, offset, length)
    return this.object(key, meta, body, options.range ? { offset, length } : undefined)
  }

  async delete(keys: string | ReadonlyArray<string>): Promise<void> {
    for (const k of typeof keys === "string" ? [keys] : keys) {
      const file = this.path(k)
      if (file === null) continue
      // rm removes a link itself, never its target; the directory it removes from is checked first.
      this.checkDir(dirname(file), "key")
      this.remove(file, "key")
      this.remove(`${file}.meta.json`, "key")
    }
  }

  async list(options: { prefix?: string; limit?: number; cursor?: string } = {}): Promise<{ objects: Array<FsObject>; truncated: boolean; cursor?: string; delimitedPrefixes: Array<string> }> {
    // R2 takes 1 to 1,000 keys a page and refuses anything else.
    const limit = options.limit ?? 1000
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1000) throw new FsBucketError("InvalidMaxKeys", "MaxKeys params must be positive integer <= 1000.")
    const out: Array<FsObject> = []
    const walk = (dir: string) => {
      // A directory swapped for a link since its parent was read is not walked.
      try {
        this.checkDir(dir, "key")
      } catch {
        return
      }
      // Entries are typed without following links, so a link (dangling or not) is skipped, never walked.
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const name = entry.name
        // Open uploads and their parts are not objects; skip the directory rather than walk it.
        if (dir === this.root && isReserved(name)) continue
        const p = join(dir, name)
        if (entry.isDirectory()) walk(p)
        else if (entry.isFile() && !name.endsWith(".meta.json") && !name.includes(".tmp-")) {
          const key = relative(this.root, p).split(sep).join("/")
          // A file no key could have written (a backslash in its name, say) is not an object.
          if (!isKey(this.root, key)) continue
          // Do not hash unrelated objects while a conversation prefix is being listed for GC.
          if (options.prefix && !key.startsWith(options.prefix)) continue
          // The walk already checked every directory above p, so only the files themselves are opened.
          let meta: StoredMeta | null
          try {
            meta = this.metaAt(p)
          } catch {
            meta = null
          }
          if (meta && (!options.prefix || key.startsWith(options.prefix))) out.push(this.object(key, meta))
          else if (!meta && (!options.prefix || key.startsWith(options.prefix))) {
            // A crash after publishing bytes but before its sidecar leaves an orphan that normal
            // listing would otherwise hide from conversation cleanup. Remove it via the held
            // parent descriptor; malformed sidecars are removed with the orphan as well.
            try {
              this.remove(p, "key")
              if (lstatOrNull(`${p}.meta.json`)?.isFile()) this.remove(`${p}.meta.json`, "key")
            } catch {
              // A concurrent writer or a link swap will be retried by the next listing pass.
            }
          }
        }
      }
    }
    walk(this.root)
    out.sort((a, b) => (a.key < b.key ? -1 : 1))
    const start = options.cursor ? out.findIndex((object) => object.key > options.cursor!) : 0
    if (start < 0) return { objects: [], truncated: false, delimitedPrefixes: [] }
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
