import { ATTACHMENT_LIMITS, DERIVED_IMAGE_TYPES, isSha256 } from "./attachments.ts"
import type { LinkPreviewPart } from "./types.ts"

/**
 * `link_preview` parts (iMessage-style sender-side previews): the sender fetches a page's title,
 * site name and image and sends them as a part; receivers render only from the part. The same
 * pure rules as the Rust crate (cmux-conversation `link_preview.rs`).
 *
 * The image is an ordinary attachment record the sender uploaded to this conversation (JPEG or
 * WebP, at most the image preview cap); a cloud owner checks it like an attachment part's hash
 * (attachments.ts `checkAttachments`), this module only its shape.
 */
export const LINK_PREVIEW_LIMITS = { maxUrlBytes: 2048, maxTitleChars: 300, maxSiteChars: 253 } as const

/** Rust `char::is_control` (Cc), `char::is_whitespace` (White_Space), and the backslash. */
const URL_REFUSED = /[\p{Cc}\p{White_Space}\\]/u
const CONTROL = /\p{Cc}/u

/**
 * An `http://` or `https://` URL (scheme case-insensitive) of 1..2048 UTF-8 bytes with a non-empty
 * authority, no user info, and no whitespace, control characters or backslashes. A plain rule,
 * not WHATWG parsing, so the Rust owner applies exactly the same one.
 */
export const validLinkUrl = (url: unknown): url is string => {
  if (typeof url !== "string" || url.length === 0 || Buffer.byteLength(url, "utf8") > LINK_PREVIEW_LIMITS.maxUrlBytes || URL_REFUSED.test(url)) return false
  const lower = url.slice(0, 8).toLowerCase()
  const rest = lower.startsWith("https://") ? url.slice(8) : lower.startsWith("http://") ? url.slice(7) : null
  if (rest === null) return false
  const authority = rest.split(/[/?#]/, 1)[0] ?? ""
  return authority.length > 0 && !authority.includes("@")
}

const validLabel = (value: unknown, maxChars: number): boolean => {
  if (value === undefined) return true
  if (typeof value !== "string") return false
  const count = [...value].length
  return count > 0 && count <= maxChars && !CONTROL.test(value)
}

/** Validates one `link_preview` part; returns it with only the known fields, or null when invalid. */
export const cleanLinkPreviewPart = (part: Record<string, unknown>): LinkPreviewPart | null => {
  const { url, title, site, image } = part
  if (!validLinkUrl(url) || !validLabel(title, LINK_PREVIEW_LIMITS.maxTitleChars) || !validLabel(site, LINK_PREVIEW_LIMITS.maxSiteChars)) return null
  let cleanImage: LinkPreviewPart["image"]
  if (image !== undefined) {
    if (typeof image !== "object" || image === null) return null
    const v = image as Record<string, unknown>
    const okSize = Number.isInteger(v.byte_count) && (v.byte_count as number) > 0 && (v.byte_count as number) <= ATTACHMENT_LIMITS.previewMaxBytes
    if (!isSha256(v.hash) || typeof v.mime_type !== "string" || !DERIVED_IMAGE_TYPES.has(v.mime_type) || !okSize) return null
    cleanImage = { hash: v.hash, mime_type: v.mime_type, byte_count: v.byte_count as number }
  }
  return {
    type: "link_preview",
    url,
    ...(title === undefined ? {} : { title: title as string }),
    ...(site === undefined ? {} : { site: site as string }),
    ...(cleanImage ? { image: cleanImage } : {})
  }
}
