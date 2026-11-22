/**
 * A minimal POSIX tar (pax/ustar) writer for streamed archives (team-vm-export.ts). It only
 * encodes headers: the caller writes each file's bytes after its header and `padding(size)` zero
 * bytes after them, then `TAR_END`. Every size is known before the first byte, so `tarLength`
 * gives the exact archive length (a Content-Length the browser can show progress against).
 */
export interface TarEntry {
  /** The archive path, relative, `/`-separated; a directory's path has no trailing slash. */
  readonly path: string
  readonly kind: "file" | "dir"
  readonly size: number
  /** Permission bits (for example 0o644). */
  readonly mode: number
  /** Modification time, seconds since the epoch. */
  readonly mtime: number
  readonly uname?: string
  readonly gname?: string
}

const BLOCK = 512
const enc = new TextEncoder()

/** Zero bytes after `size` bytes of data, up to the next 512-byte block. */
export const padding = (size: number): number => (BLOCK - (size % BLOCK)) % BLOCK

/** Two zero blocks end the archive. */
export const TAR_END = new Uint8Array(2 * BLOCK)

const octal = (n: number, width: number): string => Math.max(0, Math.floor(n)).toString(8).padStart(width - 1, "0") + "\0"

const ustarName = (e: TarEntry): string => (e.kind === "dir" ? `${e.path}/` : e.path)

/** Plain ASCII without control characters that fits the 100-byte name field; anything else gets a pax `path` record. */
const fitsUstar = (name: string): boolean => name.length <= 100 && /^[\x20-\x7e]+$/.test(name)

const paxRecord = (key: string, value: string): Uint8Array => {
  const body = enc.encode(` ${key}=${value}\n`).length
  let len = body + 1
  while (String(len).length + body !== len) len = String(len).length + body
  return enc.encode(`${len} ${key}=${value}\n`)
}

const field = (h: Uint8Array, offset: number, width: number, value: string) => {
  const bytes = enc.encode(value)
  h.set(bytes.subarray(0, width), offset)
}

const header = (name: string, type: string, size: number, e: Pick<TarEntry, "mode" | "mtime" | "uname" | "gname">): Uint8Array => {
  const h = new Uint8Array(BLOCK)
  field(h, 0, 100, name)
  field(h, 100, 8, octal(e.mode & 0o7777, 8))
  field(h, 108, 8, octal(0, 8))
  field(h, 116, 8, octal(0, 8))
  field(h, 124, 12, octal(size, 12))
  field(h, 136, 12, octal(e.mtime, 12))
  field(h, 148, 8, "        ")
  field(h, 156, 1, type)
  field(h, 257, 6, "ustar\0")
  field(h, 263, 2, "00")
  const owner = (s: string | undefined) => (s && /^[\x21-\x7e]{1,31}$/.test(s) ? s : "")
  field(h, 265, 32, owner(e.uname))
  field(h, 297, 32, owner(e.gname))
  let sum = 0
  for (const b of h) sum += b
  field(h, 148, 8, sum.toString(8).padStart(6, "0") + "\0 ")
  return h
}

/** The header block(s) of one entry: a pax extended header first when the path does not fit ustar. */
export const tarHeader = (e: TarEntry): Uint8Array => {
  const name = ustarName(e)
  const size = e.kind === "dir" ? 0 : e.size
  const type = e.kind === "dir" ? "5" : "0"
  if (fitsUstar(name)) return header(name, type, size, e)
  const pax = paxRecord("path", name)
  const out = new Uint8Array(BLOCK + pax.length + padding(pax.length) + BLOCK)
  out.set(header("././@PaxHeader", "x", pax.length, e), 0)
  out.set(pax, BLOCK)
  // The ustar name is only a fallback for readers without pax: the ASCII part, cut to 100 bytes.
  const fallback = name.replace(/[^\x20-\x7e]/g, "_").slice(-100)
  out.set(header(fallback, type, size, e), BLOCK + pax.length + padding(pax.length))
  return out
}

/** The exact length of the archive of `entries`: headers, data, padding and the end blocks. */
export const tarLength = (entries: ReadonlyArray<TarEntry>): number =>
  entries.reduce((n, e) => n + tarHeader(e).length + (e.kind === "file" ? e.size + padding(e.size) : 0), 0) + TAR_END.length
