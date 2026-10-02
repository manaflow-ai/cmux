import { createHash } from "node:crypto"
import { crockford, isCrockford } from "../invites/base32.ts"

/**
 * Pure id and timestamp helpers, equal to `cmux-conversation::id` and
 * `budget::parse_rfc3339_millis`. The host supplies the clock reading and the
 * random bytes.
 */

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

/**
 * `<prefix><26 Crockford base32 chars>`: a 48-bit millisecond time followed by
 * 80 random bits (the ULID layout), so ids sort by creation time.
 */
export const encodeId = (prefix: string, unixMs: number, random: Uint8Array): string => {
  if (random.length !== 10) throw new Error("encodeId needs exactly 10 random bytes")
  let value = (BigInt(Math.trunc(unixMs)) & 0xffff_ffff_ffffn) << 80n
  for (let index = 0; index < 10; index++) value |= BigInt(random[index] ?? 0) << BigInt(8 * (9 - index))
  let id = prefix
  for (let index = 0; index < 26; index++) id += CROCKFORD[Number((value >> BigInt(5 * (25 - index))) & 31n)]
  return id
}

/**
 * The id of the dm between two participants (home-messaging.md section 2):
 * `conv_dm_` + base32(sha256("dm\0" + lo + "\0" + hi))[0..26], where lo and
 * hi are the two ids sorted. Participant ids are ASCII, so UTF-16 order equals
 * Rust's byte order.
 */
export const dmConversationId = (a: string, b: string): string => {
  const [lo, hi] = a < b ? [a, b] : [b, a]
  const digest = createHash("sha256").update(`dm\0${lo}\0${hi}`).digest()
  return `conv_dm_${crockford(digest, 26)}`
}

/** RFC 3339 UTC with milliseconds, for example `2026-10-01T12:34:56.789Z`. */
export const formatRfc3339Millis = (unixMs: number): string => {
  const millis = unixMs % 1000
  const seconds = Math.floor(unixMs / 1000)
  const days = Math.floor(seconds / 86_400)
  const secondOfDay = seconds % 86_400
  const [year, month, day] = civilFromDays(days)
  const pad = (value: number, width: number) => String(value).padStart(width, "0")
  return (
    `${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}T${pad(Math.floor(secondOfDay / 3600), 2)}:` +
    `${pad(Math.floor((secondOfDay % 3600) / 60), 2)}:${pad(secondOfDay % 60, 2)}.${pad(millis, 3)}Z`
  )
}

/** Parses the owner's own timestamp format to Unix milliseconds, or null. */
export const parseRfc3339Millis = (text: string): number | null => {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{3})Z$/.exec(text)
  if (!match) return null
  const [year, month, day, hour, minute, second, millis] = match.slice(1).map(Number) as [
    number,
    number,
    number,
    number,
    number,
    number,
    number
  ]
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return null
  const days = daysFromCivil(year, month, day)
  if (days === null) return null
  return (days * 86_400 + hour * 3600 + minute * 60 + second) * 1000 + millis
}

/** Howard Hinnant's `civil_from_days`, for non-negative day counts. */
const civilFromDays = (days: number): [number, number, number] => {
  const z = days + 719_468
  const era = Math.floor(z / 146_097)
  const dayOfEra = z % 146_097
  const yearOfEra = Math.floor((dayOfEra - Math.floor(dayOfEra / 1460) + Math.floor(dayOfEra / 36_524) - Math.floor(dayOfEra / 146_096)) / 365)
  const dayOfYear = dayOfEra - (365 * yearOfEra + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100))
  const monthIndex = Math.floor((5 * dayOfYear + 2) / 153)
  const day = dayOfYear - Math.floor((153 * monthIndex + 2) / 5) + 1
  const month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
  return [yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day]
}

/** Howard Hinnant's `days_from_civil`, null before 1970-01-01 (as in Rust). */
const daysFromCivil = (year: number, month: number, day: number): number | null => {
  const y = month <= 2 ? year - 1 : year
  if (y < 0) return null
  const era = Math.floor(y / 400)
  const yearOfEra = y - era * 400
  const monthIndex = month > 2 ? month - 3 : month + 9
  const dayOfYear = Math.floor((153 * monthIndex + 2) / 5) + day - 1
  const dayOfEra = yearOfEra * 365 + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100) + dayOfYear
  const days = era * 146_097 + dayOfEra - 719_468
  return days < 0 ? null : days
}

/** An opaque client token (idempotency key, `client_msg_id`): 1 to 128 printable ASCII characters. */
export const validToken = (token: string): boolean => {
  if (token.length === 0 || token.length > 128) return false
  for (let index = 0; index < token.length; index++) {
    const code = token.charCodeAt(index)
    if (code < 0x21 || code > 0x7e) return false
  }
  return true
}

/**
 * `user_<id>` or `agent_<name>`, where the suffix is 1 to 64 characters of
 * ASCII letters, digits, `_`, `.` or `-` (the Rust rule; mentions use it too).
 */
export const validParticipantId = (id: string): boolean => /^(user|agent)_[A-Za-z0-9_.-]{1,64}$/.test(id)

/** Cloud: `contact_<26 Crockford base32>`. */
export const validContactId = (id: string): boolean => id.startsWith("contact_") && isCrockford(id.slice(8), 26)

/** Cloud: `inv_<26 Crockford base32>`. */
export const validInviteId = (id: string): boolean => id.startsWith("inv_") && isCrockford(id.slice(4), 26)
