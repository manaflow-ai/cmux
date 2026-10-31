import { isSha256 } from "./attachments.ts"
import { validLinkUrl } from "./link-preview.ts"
import type { AttachmentPart, CardImage, CardPart, Part } from "./types.ts"

/**
 * `card` parts (https://github.com/manaflow-ai/cmux/issues/25830): a Chief's live browser card, a
 * Secure Store sign-in card and next-step chips, tagged by `kind`. Only an agent posts one
 * (apply.ts). The same pure rules as the Rust crate (cmux-conversation `card.rs`); an unknown kind
 * is refused with `invalid_parts`.
 *
 * A browser card's `image` is an ordinary attachment record the agent uploaded to this
 * conversation; a cloud owner checks it like an attachment part's hash (attachments.ts
 * `checkAttachments`), this module only its shape.
 */
export const CARD_LIMITS = {
  maxStepChars: 200,
  maxSiteChars: 253,
  maxChoices: 3,
  maxChoiceChars: 120,
  maxMachineIdChars: 128,
  /** 4 MiB. */
  maxImageBytes: 4 * 1024 * 1024,
  maxImageDimension: 16_384
} as const

export const CARD_IMAGE_TYPES: ReadonlySet<string> = new Set(["image/png", "image/jpeg", "image/webp"])

const CONTROL = /\p{Cc}/u
const SITE = /^[a-z0-9.-]+$/
const MACHINE_ID = /^[A-Za-z0-9_-]+$/

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value)

/** 1..max code points, no control characters. */
const validLabel = (value: unknown, maxChars: number): value is string => {
  if (typeof value !== "string") return false
  const count = [...value].length
  return count > 0 && count <= maxChars && !CONTROL.test(value)
}

/** A lowercase DNS name: 1..253 characters of `[a-z0-9.-]` with at least one dot, no empty label, not starting or ending with `.` or `-` (Rust `valid_card_site`). */
export const validCardSite = (site: unknown): site is string =>
  typeof site === "string" &&
  site.length > 0 &&
  site.length <= CARD_LIMITS.maxSiteChars &&
  SITE.test(site) &&
  site.includes(".") &&
  !site.includes("..") &&
  !/^[.-]|[.-]$/.test(site)

/** `browser:right`, or `machine:<id>` with id `[A-Za-z0-9_-]{1,128}`. */
export const validCardTarget = (target: unknown): target is string => {
  if (target === "browser:right") return true
  if (typeof target !== "string" || !target.startsWith("machine:")) return false
  const id = target.slice("machine:".length)
  return id.length > 0 && id.length <= CARD_LIMITS.maxMachineIdChars && MACHINE_ID.test(id)
}

const validDimension = (value: unknown): boolean =>
  value === undefined || (Number.isInteger(value) && (value as number) >= 1 && (value as number) <= CARD_LIMITS.maxImageDimension)

const cleanImage = (image: unknown): CardImage | null => {
  if (!isObject(image)) return null
  const width = image.width === null ? undefined : image.width
  const height = image.height === null ? undefined : image.height
  const size = image.byte_count
  const okSize = Number.isInteger(size) && (size as number) >= 1 && (size as number) <= CARD_LIMITS.maxImageBytes
  if (!isSha256(image.hash) || typeof image.mime_type !== "string" || !CARD_IMAGE_TYPES.has(image.mime_type) || !okSize) return null
  if (!validDimension(width) || !validDimension(height)) return null
  return {
    hash: image.hash,
    mime_type: image.mime_type,
    byte_count: size as number,
    ...(width === undefined ? {} : { width: width as number }),
    ...(height === undefined ? {} : { height: height as number })
  }
}

/** Validates one `card` part; returns it with only the known fields, or null when invalid. */
export const cleanCardPart = (part: Record<string, unknown>): CardPart | null => {
  // A null optional field is absent, as the Rust owner reads it (serde `Option`).
  const absent = (value: unknown) => (value === null ? undefined : value)
  switch (part.kind) {
    case "browser": {
      const { surface, step } = part
      const live = part.live === undefined ? false : part.live
      const target = absent(part.target)
      const url = absent(part.url)
      const image = absent(part.image)
      if (surface !== "browser" && surface !== "computer") return null
      if (!validLabel(step, CARD_LIMITS.maxStepChars) || typeof live !== "boolean") return null
      if (target !== undefined && !validCardTarget(target)) return null
      if (url !== undefined && !validLinkUrl(url)) return null
      const clean = image === undefined ? undefined : cleanImage(image)
      if (clean === null) return null
      return {
        type: "card",
        kind: "browser",
        surface,
        step,
        live,
        ...(target === undefined ? {} : { target }),
        ...(url === undefined ? {} : { url: url as string }),
        ...(clean === undefined ? {} : { image: clean })
      }
    }
    case "sign_in": {
      const url = absent(part.url)
      if (!validCardSite(part.site)) return null
      if (url !== undefined && !validLinkUrl(url)) return null
      return { type: "card", kind: "sign_in", site: part.site, ...(url === undefined ? {} : { url: url as string }) }
    }
    case "next_steps": {
      const { choices } = part
      if (!Array.isArray(choices) || choices.length === 0 || choices.length > CARD_LIMITS.maxChoices) return null
      if (!choices.every((choice) => validLabel(choice, CARD_LIMITS.maxChoiceChars))) return null
      if (new Set(choices).size !== choices.length) return null
      return { type: "card", kind: "next_steps", choices: [...(choices as Array<string>)] }
    }
    default:
      return null
  }
}

/** The text a reader without card support shows (transcripts, previews, search). */
export const cardText = (card: CardPart): string => {
  switch (card.kind) {
    case "browser":
      return `${card.surface === "computer" ? "Computer" : "Browser"}: ${card.step}`
    case "sign_in":
      return `Secure Store: sign in to ${card.site}`
    case "next_steps":
      return card.choices.map((choice) => `→ ${choice}`).join("\n")
  }
}

/**
 * A browser card's screenshot served as an attachment of its own record (like a link preview's
 * image). Undefined when the part is not a browser card holding `hash`.
 */
export const cardImageHeldBy = (part: Part | undefined, hash: string): AttachmentPart | undefined => {
  if (part?.type !== "card" || part.kind !== "browser" || part.image?.hash !== hash) return undefined
  const { mime_type, byte_count, width, height } = part.image
  const ext = mime_type === "image/png" ? "png" : mime_type === "image/webp" ? "webp" : "jpg"
  return {
    type: "attachment",
    hash,
    name: `browser-card.${ext}`,
    mime_type,
    byte_count,
    ...(width === undefined ? {} : { width }),
    ...(height === undefined ? {} : { height })
  }
}
