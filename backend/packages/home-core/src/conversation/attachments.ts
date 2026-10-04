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
/** Every attachment limit in one place (decimal megabytes; backend lead decisions 2026-10-03). */
export const ATTACHMENT_LIMITS = {
  /** Per file, every type. */
  maxBytes: 100 * MB,
  /** Up to this size the bytes stream through the Worker (Free plan body cap is 100 MB); larger files use a presigned R2 PUT. */
  streamMaxBytes: 32 * MB,
  /** Per user, rolling 24 h: declared bytes and intents; stored bytes per uploader across conversations. */
  quota: { dayBytes: 2_000 * MB, dayIntents: 300, storedBytes: 10_000 * MB, dayMs: 24 * 3_600_000 },
  maxNameChars: 255,
  maxDimension: 100_000,
  maxDurationMs: 24 * 3_600_000,
  /** Upload slot (both modes) and download URL lifetimes. */
  uploadTtlMs: 15 * 60_000,
  downloadTtlMs: 10 * 60_000,
  /** An uploaded object no message references is collectable after this long. */
  unreferencedGraceMs: 24 * 3_600_000
} as const

/** The allow list: type -> class. SVG, HTML and XML are never on it. */
export const ATTACHMENT_TYPES: Readonly<Record<string, AttachmentClass>> = {
  "image/jpeg": "image",
  "image/png": "image",
  "image/gif": "image",
  "image/webp": "image",
  "image/heic": "image",
  "application/pdf": "file",
  "text/plain": "file",
  "text/markdown": "file",
  "text/csv": "file",
  "application/json": "file",
  "application/zip": "file",
  "video/mp4": "video",
  "video/quicktime": "video",
  "audio/mp4": "audio",
  "audio/mpeg": "audio",
  "audio/aac": "audio",
  "audio/wav": "audio"
}

/** Text types download as text/plain attachments (never rendered as their own type). */
export const servedContentType = (mime: string): string => (mime.startsWith("text/") || mime === "application/json" ? "text/plain; charset=utf-8" : mime)

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
  const cap = ATTACHMENT_LIMITS.maxBytes
  if ((v.byte_count as number) > cap) return { ok: false, code: "attachment.too_large", message: `attachments are limited to ${cap} bytes` }
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
 * (written only after the bytes were verified). Never sent to subscribers; the file name lives
 * only in message parts.
 */
export interface AttachmentRecord {
  readonly hash: string
  /** Random id: the R2 key suffix and the id in download URLs (a hash never appears in a URL). */
  readonly object_id: string
  /** R2 key `home/v1/<conversation>/<object id>`. */
  readonly object_key: string
  readonly mime_type: string
  readonly byte_count: number
  /** R2 etag at commit; downloads read only this version. */
  readonly etag?: string
  /** Actors who uploaded these bytes here (each may use the object before any message references it). */
  readonly uploaders: ReadonlyArray<string>
  /** The user whose stored-bytes quota the object counts against (the first uploader's user). */
  readonly quota_user: string
  readonly created_at: number
}

export const attachmentObjectKey = (conversation: string, objectId: string) => `home/v1/${conversation}/${objectId}`
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

/**
 * The record of `hash` only when `actor` may use it: an uploader of it in this conversation, or a
 * message above the actor's history floor references it. Anything else (no such upload, another
 * member's unsent upload, hidden pre-join history) is undefined, so callers cannot tell them apart.
 */
export type AttachmentLookup = (hash: string, actor: string, floor: number) => AttachmentRecord | undefined

/** The owner's check for `actor`: each part's hash (and poster) is usable by the author, and its type and size match the record. */
export const checkAttachments = (parts: ReadonlyArray<Part>, lookup: AttachmentLookup, actor: string, floor: number): "unknown_attachment" | "attachment_mismatch" | null => {
  for (const p of parts) {
    if (p.type !== "attachment") continue
    const rec = lookup(p.hash, actor, floor)
    if (!rec) return "unknown_attachment"
    if (rec.mime_type !== p.mime_type || rec.byte_count !== p.byte_count) return "attachment_mismatch"
    if (p.poster_hash !== undefined) {
      const poster = lookup(p.poster_hash, actor, floor)
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

/** Row deletes when retention removes a message: the message, its client-id key and its attachment references. */
export const messageDeleteWrites = (message: Pick<Message, "id" | "author" | "client_msg_id" | "parts">): Array<RowWrite> => [
  { table: "msg", op: "delete", key: message.id },
  { table: "msgkey", op: "delete", key: `${message.author}:${message.client_msg_id}` },
  ...[...attachmentHashes(message.parts)].map((h): RowWrite => ({ table: TABLE_ATTREF, op: "delete", key: `${h}:${message.id}` }))
]

export type PreviewAttachmentKind = "photo" | "video" | "audio" | "file"
export interface PreviewAttachments {
  readonly kind: PreviewAttachmentKind
  readonly count: number
}
export const PREVIEW_ATTACHMENT_KINDS: ReadonlyArray<PreviewAttachmentKind> = ["photo", "video", "audio", "file"]
const PREVIEW_KIND: Record<AttachmentClass, PreviewAttachmentKind> = { image: "photo", video: "video", audio: "audio", file: "file" }

/** Inbox preview of a message's attachments (clients localize "2 photos"); mixed kinds are "file". */
export const previewAttachmentsOf = (message: Pick<Message, "parts">): PreviewAttachments | undefined => {
  const kinds = message.parts.flatMap((p) => (p.type === "attachment" ? [PREVIEW_KIND[ATTACHMENT_TYPES[p.mime_type] ?? "file"]] : []))
  if (kinds.length === 0) return undefined
  return { kind: kinds.every((k) => k === kinds[0]) ? kinds[0]! : "file", count: kinds.length }
}

export type QuotaResult =
  | { readonly ok: true }
  | { readonly ok: false; readonly code: "attachment.quota" | "attachment.storage_quota"; readonly window: "day_bytes" | "day_intents" | "stored"; readonly retry_after_ms: number }

export interface QuotaUsage {
  /** Byte takes `{bytes, at}`, one per upload slot (refunded ones removed). */
  readonly bytes: ReadonlyArray<{ readonly bytes: number; readonly at: number }>
  /** Intent times. */
  readonly intents: ReadonlyArray<number>
  /** Bytes of objects this user uploaded first and that still exist. */
  readonly stored: number
}

/**
 * Per user: 300 intents and 2 GB declared bytes per rolling 24 h, 10 GB stored. Every upload
 * slot is charged its declared bytes (the owner refunds a slot whose commit finds the bytes
 * already stored, or that expires unused), so bytes in flight are always counted.
 */
export const attachmentQuota = (usage: QuotaUsage, bytes: number, now: number): QuotaResult => {
  const q = ATTACHMENT_LIMITS.quota
  const since = now - q.dayMs
  const intents = usage.intents.filter((t) => t > since).sort((a, b) => a - b)
  if (intents.length >= q.dayIntents) return { ok: false, code: "attachment.quota", window: "day_intents", retry_after_ms: Math.max(1, intents[intents.length - q.dayIntents]! + q.dayMs - now) }
  if (usage.stored + bytes > q.storedBytes) return { ok: false, code: "attachment.storage_quota", window: "stored", retry_after_ms: 0 }
  const inside = usage.bytes.filter((u) => u.at > since).sort((a, b) => a.at - b.at)
  let total = inside.reduce((sum, u) => sum + u.bytes, 0)
  if (total + bytes <= q.dayBytes) return { ok: true }
  // Retry when enough of the oldest takes have left the window.
  let at = now
  for (const u of inside) {
    total -= u.bytes
    at = u.at + q.dayMs
    if (total + bytes <= q.dayBytes) break
  }
  return { ok: false, code: "attachment.quota", window: "day_bytes", retry_after_ms: Math.max(1, at - now) }
}

/** Raster images render inline; everything else downloads (stored XSS defense with nosniff and a sandbox CSP). */
export const contentDisposition = (mime: string, name: string): string => {
  // Header-safe: control characters never reach the header.
  name = name.replace(/[\p{Cc}\u2028\u2029]/gu, "_")
  const kind = ATTACHMENT_TYPES[mime] === "image" ? "inline" : "attachment"
  const ascii = name.replace(/[^\x20-\x7e]/g, "_").replace(/["\\]/g, "_")
  return `${kind}; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`
}
