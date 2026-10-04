import type { RowWrite } from "./engine-types.ts"
import type { AttachmentPart, Message, Part } from "./types.ts"

/**
 * Home attachments (home-messaging.md section 2, `attachment` part): pure rules shared by the
 * Worker (upload intent), the ConversationDO (message.send) and tests.
 *
 * Flow: the client asks for an upload slot with the SHA-256 of the bytes; the Worker checks the
 * caller, the type, the size and the quota; the bytes go to R2 through the Worker, which hashes
 * them and records the object in the ConversationDO only when the hash matches; a message part
 * then references the hash. Records are per conversation: one conversation never learns that
 * another holds the same bytes.
 */

export type AttachmentClass = "image" | "video" | "audio" | "file"

const MB = 1_000_000
/** Every attachment limit in one place. Decimal megabytes (100 MB stays under Cloudflare's 100 MiB request body cap on every plan). */
export const ATTACHMENT_LIMITS = {
  maxBytes: { image: 25 * MB, video: 100 * MB, audio: 25 * MB, file: 25 * MB } satisfies Record<AttachmentClass, number>,
  /** Per user, declared bytes of upload intents (a repeated intent for the same conversation and hash counts once). */
  quota: { dayBytes: 1_000 * MB, monthBytes: 10_000 * MB, dayMs: 24 * 3_600_000, monthMs: 30 * 24 * 3_600_000 },
  maxNameChars: 255,
  maxDimension: 100_000,
  maxDurationMs: 24 * 3_600_000,
  /** Upload slot and download URL lifetimes. */
  uploadTtlMs: 15 * 60_000,
  downloadTtlMs: 10 * 60_000,
  /** An uploaded object no message references is collectable after this long. */
  unreferencedGraceMs: 24 * 3_600_000
} as const

/** The allow list: type -> class. SVG, HTML, XML, scripts and executables are absent on purpose. */
export const ATTACHMENT_TYPES: Readonly<Record<string, AttachmentClass>> = {
  "image/jpeg": "image",
  "image/png": "image",
  "image/gif": "image",
  "image/webp": "image",
  "image/heic": "image",
  "image/heif": "image",
  "image/avif": "image",
  "video/mp4": "video",
  "video/quicktime": "video",
  "video/webm": "video",
  "audio/mpeg": "audio",
  "audio/mp4": "audio",
  "audio/aac": "audio",
  "audio/wav": "audio",
  "audio/ogg": "audio",
  "audio/webm": "audio",
  "audio/flac": "audio",
  "application/pdf": "file",
  "text/plain": "file",
  "text/markdown": "file",
  "text/csv": "file",
  "application/json": "file",
  "application/rtf": "file",
  "application/zip": "file",
  "application/gzip": "file",
  "application/x-tar": "file",
  "application/x-7z-compressed": "file",
  "application/msword": "file",
  "application/vnd.ms-excel": "file",
  "application/vnd.ms-powerpoint": "file",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "file",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "file",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation": "file",
  "application/vnd.oasis.opendocument.text": "file",
  "application/vnd.oasis.opendocument.spreadsheet": "file",
  "application/vnd.oasis.opendocument.presentation": "file",
  "application/vnd.apple.pages": "file",
  "application/vnd.apple.numbers": "file",
  "application/vnd.apple.keynote": "file"
}

/** Extensions refused whatever the declared type (executables, installers, scripts, active documents). */
export const DENIED_EXTENSIONS: ReadonlySet<string> = new Set([
  "exe", "dll", "msi", "msp", "msix", "appx", "bat", "cmd", "com", "scr", "pif", "cpl", "msc", "hta", "gadget", "lnk", "reg", "inf",
  "ps1", "psm1", "vbs", "vbe", "js", "jse", "mjs", "cjs", "wsf", "wsh", "jar", "class",
  "app", "dmg", "pkg", "mpkg", "command", "workflow", "action", "scpt", "applescript", "terminal", "tool", "kext", "dylib", "so",
  "sh", "bash", "zsh", "csh", "fish", "ksh", "run", "bin", "elf", "apk", "aab", "ipa", "deb", "rpm", "appimage", "snap", "flatpak",
  "html", "htm", "xhtml", "shtml", "svg", "svgz", "xml", "xsl", "mht", "mhtml", "webloc", "url", "desktop", "iso", "img", "vhd", "vhdx"
])

export const isSha256 = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{64}$/.test(value)

const extensionOf = (name: string): string => {
  const dot = name.lastIndexOf(".")
  return dot < 0 ? "" : name.slice(dot + 1).toLowerCase()
}

/** A display file name: 1..255 characters, no control characters, no path separators, not `.`/`..`. */
export const validAttachmentName = (name: unknown): name is string =>
  typeof name === "string" &&
  [...name].length > 0 &&
  [...name].length <= ATTACHMENT_LIMITS.maxNameChars &&
  !/[\p{Cc}\u2028\u2029/\\]/u.test(name) &&
  name.trim() !== "" &&
  name !== "." &&
  name !== ".."

export const deniedName = (name: string): boolean => DENIED_EXTENSIONS.has(extensionOf(name))

const positiveInt = (v: unknown, max: number) => Number.isInteger(v) && (v as number) > 0 && (v as number) <= max
const optional = (v: unknown, check: (v: unknown) => boolean) => v === undefined || v === null || check(v)

export interface AttachmentMeta {
  readonly sha256: string
  readonly byte_count: number
  readonly mime_type: string
  readonly name: string
  readonly width?: number
  readonly height?: number
  readonly duration_ms?: number
}

export type MetaResult =
  | { readonly ok: true; readonly class: AttachmentClass; readonly meta: AttachmentMeta }
  | { readonly ok: false; readonly code: "validation.invalid" | "attachment.type_refused" | "attachment.too_large"; readonly message: string }

/** Upload intent rules: shape, the allow list, denied extensions, and the class size cap. */
export const validateAttachmentMeta = (input: unknown): MetaResult => {
  const bad = (message: string): MetaResult => ({ ok: false, code: "validation.invalid", message })
  if (typeof input !== "object" || input === null) return bad("body must be an object")
  const v = input as Record<string, unknown>
  if (!isSha256(v.sha256)) return bad("sha256 must be 64 lowercase hex characters")
  if (!Number.isInteger(v.byte_count) || (v.byte_count as number) <= 0) return bad("byte_count must be a positive integer")
  if (typeof v.mime_type !== "string") return bad("mime_type is required")
  if (!validAttachmentName(v.name)) return bad("name must be 1 to 255 characters without control characters or path separators")
  if (!optional(v.width, (x) => positiveInt(x, ATTACHMENT_LIMITS.maxDimension)) || !optional(v.height, (x) => positiveInt(x, ATTACHMENT_LIMITS.maxDimension))) return bad("width and height must be positive integers")
  if (!optional(v.duration_ms, (x) => Number.isInteger(x) && (x as number) >= 0 && (x as number) <= ATTACHMENT_LIMITS.maxDurationMs)) return bad("duration_ms out of range")
  const mime = v.mime_type.toLowerCase()
  const cls = ATTACHMENT_TYPES[mime]
  if (!cls || deniedName(v.name)) return { ok: false, code: "attachment.type_refused", message: "this file type cannot be sent" }
  const cap = ATTACHMENT_LIMITS.maxBytes[cls]
  if ((v.byte_count as number) > cap) return { ok: false, code: "attachment.too_large", message: `${cls} attachments are limited to ${cap} bytes` }
  return {
    ok: true,
    class: cls,
    meta: {
      sha256: v.sha256,
      byte_count: v.byte_count as number,
      mime_type: mime,
      name: v.name,
      ...(typeof v.width === "number" ? { width: v.width } : {}),
      ...(typeof v.height === "number" ? { height: v.height } : {}),
      ...(typeof v.duration_ms === "number" ? { duration_ms: v.duration_ms } : {})
    }
  }
}

/** Validates one `attachment` part (shape and the same type, name and size rules); throws nothing, returns null when invalid. */
export const cleanAttachmentPart = (part: Record<string, unknown>): AttachmentPart | null => {
  const r = validateAttachmentMeta({ ...part, sha256: part.hash })
  if (!r.ok || r.meta.mime_type !== part.mime_type) return null
  if (!optional(part.poster_hash, isSha256)) return null
  return {
    type: "attachment",
    hash: r.meta.sha256,
    name: r.meta.name,
    mime_type: r.meta.mime_type,
    byte_count: r.meta.byte_count,
    ...(r.meta.width === undefined ? {} : { width: r.meta.width }),
    ...(r.meta.height === undefined ? {} : { height: r.meta.height }),
    ...(r.meta.duration_ms === undefined ? {} : { duration_ms: r.meta.duration_ms }),
    ...(typeof part.poster_hash === "string" ? { poster_hash: part.poster_hash } : {})
  }
}

/**
 * An uploaded object of one conversation, kept by its ConversationDO outside the op stream
 * (written only after the Worker verified the bytes' hash). Never sent to subscribers.
 */
export interface AttachmentRecord {
  readonly hash: string
  /** R2 key `home/v1/<conversation>/<sha256>/<upload id>`. */
  readonly object_key: string
  readonly mime_type: string
  readonly byte_count: number
  readonly name: string
  /** Who uploaded these bytes here (each may see the object before any message references it). */
  readonly uploaders: ReadonlyArray<string>
  readonly created_at: number
}

export const attachmentObjectKey = (conversation: string, sha256: string, uploadId: string) => `home/v1/${conversation}/${sha256}/${uploadId}`
export const attachmentPrefix = (conversation: string) => `home/v1/${conversation}/`

/**
 * Private row table of references: key `<hash>:<message id>`, row {hash, message_id, seq}.
 * Written in the message's own commit, so "referenced" is exact: send adds, edit moves, retract
 * removes. An object with no reference row (after the grace period) is collectable.
 */
export const TABLE_ATTREF = "attref"

/** Every hash a part list references (the file and its poster). */
export const attachmentHashes = (parts: ReadonlyArray<Part>): Set<string> => {
  const out = new Set<string>()
  for (const p of parts) {
    if (p.type !== "attachment") continue
    out.add(p.hash)
    if (p.poster_hash) out.add(p.poster_hash)
  }
  return out
}

export type AttachmentLookup = (hash: string) => AttachmentRecord | undefined

/** The owner's check: each part's hash (and poster) was uploaded here, and its type and size match the record. */
export const checkAttachments = (parts: ReadonlyArray<Part>, lookup: AttachmentLookup): "unknown_attachment" | "attachment_mismatch" | null => {
  for (const p of parts) {
    if (p.type !== "attachment") continue
    const rec = lookup(p.hash)
    if (!rec) return "unknown_attachment"
    if (rec.mime_type !== p.mime_type || rec.byte_count !== p.byte_count) return "attachment_mismatch"
    if (p.poster_hash !== undefined) {
      const poster = lookup(p.poster_hash)
      if (!poster) return "unknown_attachment"
      if (ATTACHMENT_TYPES[poster.mime_type] !== "image") return "attachment_mismatch"
    }
  }
  return null
}

/** Reference rows to write when `message` replaces `before` (send: before = null; retract: message.parts = []). */
export const attachmentRefWrites = (before: Message | null, message: Message): Array<RowWrite> => {
  const old = before ? attachmentHashes(before.parts) : new Set<string>()
  const now = attachmentHashes(message.parts)
  const writes: Array<RowWrite> = []
  for (const h of old) if (!now.has(h)) writes.push({ table: TABLE_ATTREF, op: "delete", key: `${h}:${message.id}` })
  for (const h of now) if (!old.has(h)) writes.push({ table: TABLE_ATTREF, op: "upsert", key: `${h}:${message.id}`, n: null, row: { hash: h, message_id: message.id, seq: message.seq } })
  return writes
}

export type QuotaResult = { readonly ok: true } | { readonly ok: false; readonly window: "day" | "month"; readonly retry_after_ms: number }

/** Rolling day and month windows over earlier takes `{bytes, at}`; refuses when `bytes` would pass either cap. */
export const attachmentQuota = (used: ReadonlyArray<{ readonly bytes: number; readonly at: number }>, bytes: number, now: number): QuotaResult => {
  const q = ATTACHMENT_LIMITS.quota
  for (const [window, ms, cap] of [["day", q.dayMs, q.dayBytes], ["month", q.monthMs, q.monthBytes]] as const) {
    const inside = used.filter((u) => u.at > now - ms).sort((a, b) => a.at - b.at)
    let total = inside.reduce((s, u) => s + u.bytes, 0)
    if (total + bytes <= cap) continue
    // Retry when enough of the oldest takes have left the window.
    let at = now
    for (const u of inside) {
      total -= u.bytes
      at = u.at + ms
      if (total + bytes <= cap) break
    }
    return { ok: false, window, retry_after_ms: Math.max(1, at - now) }
  }
  return { ok: true }
}

/** Raster images render inline; everything else downloads (stored XSS defense with nosniff and a sandbox CSP). */
export const contentDisposition = (mime: string, name: string): string => {
  const kind = ATTACHMENT_TYPES[mime] === "image" ? "inline" : "attachment"
  const ascii = name.replace(/[^\x20-\x7e]/g, "_").replace(/["\\]/g, "_")
  return `${kind}; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`
}
