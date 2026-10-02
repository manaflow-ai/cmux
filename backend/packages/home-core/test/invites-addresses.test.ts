import { describe, expect, it } from "vitest"
import {
  contactId,
  hashInviteSecret,
  inviteLink,
  maskAddress,
  newInviteSecret,
  normalizeAddress,
  normalizeEmail,
  normalizePhone,
  parseInviteLink,
  secretMatches
} from "../src/invites/index.ts"

const KEY = "test-contact-key-0123456789abcdefghijkl"

describe("addresses", () => {
  it("normalizes email to lowercase and keeps plus addressing", () => {
    expect(normalizeEmail("  Alex+cmux@Example.COM ")).toEqual({ channel: "email", value: "alex+cmux@example.com" })
    for (const bad of ["alex", "alex@", "@example.com", "a..b@example.com", "a@-example.com", "a@example"]) expect(normalizeEmail(bad)).toBe("address.invalid")
  })

  it("normalizes North American numbers to E.164", () => {
    for (const input of ["(415) 555-0123", "415.555.0123", "+1 415 555 0123", "1-415-555-0123", "0014155550123"])
      expect(normalizePhone(input)).toEqual({ channel: "sms", value: "+14155550123" })
  })

  it("refuses other countries, toll-free and malformed numbers", () => {
    expect(normalizePhone("+44 20 7946 0958")).toBe("address.country_not_allowed")
    expect(normalizePhone("+1 800 555 0123")).toBe("address.not_mobile")
    expect(normalizePhone("+1 115 555 0123")).toBe("address.invalid")
    expect(normalizePhone("555-0123")).toBe("address.invalid")
    expect(normalizePhone("call me")).toBe("address.invalid")
  })

  it("routes by @", () => {
    expect(normalizeAddress("a@example.com")).toEqual({ channel: "email", value: "a@example.com" })
    expect(normalizeAddress("4155550123")).toEqual({ channel: "sms", value: "+14155550123" })
  })

  it("derives a stable keyed contact id", () => {
    const a = contactId(KEY, { channel: "email", value: "a@example.com" })
    expect(a).toMatch(/^contact_[0-9A-HJKMNP-TV-Z]{26}$/)
    expect(contactId(KEY, { channel: "email", value: "a@example.com" })).toBe(a)
    expect(contactId(`${KEY}x`, { channel: "email", value: "a@example.com" })).not.toBe(a)
    expect(contactId(KEY, { channel: "sms", value: "a@example.com" })).not.toBe(a)
    expect(() => contactId("short", { channel: "email", value: "a@example.com" })).toThrow()
  })

  it("masks addresses for other members", () => {
    expect(maskAddress({ channel: "email", value: "alex@example.com" })).toBe("a***@example.com")
    expect(maskAddress({ channel: "sms", value: "+14155550123" })).toBe("+1 *** *** 0123")
  })
})

describe("invite secrets and links", () => {
  const bytes = Uint8Array.from({ length: 16 }, (_, i) => i * 17)
  const conversation = "conv_01JB8Q3Z5X7Y9K2M4N6P8R0T2V"

  it("makes a 128-bit secret and matches only its hash", () => {
    const secret = newInviteSecret(bytes)
    expect(secret).toHaveLength(26)
    const hash = hashInviteSecret(secret)
    expect(secretMatches(secret, hash)).toBe(true)
    expect(secretMatches(`${secret.slice(0, 25)}0`, hash)).toBe(false)
    expect(() => newInviteSecret(new Uint8Array(8))).toThrow()
  })

  it("round-trips links with the secret in the fragment", () => {
    const secret = newInviteSecret(bytes)
    const link = inviteLink("https://cmux.com/", conversation, secret)
    expect(link).toBe(`https://cmux.com/i/g01JB8Q3Z5X7Y9K2M4N6P8R0T2V#${secret}`)
    expect(link.length).toBeLessThanOrEqual(80)
    expect(parseInviteLink(link)).toEqual({ conversation, secret })
    const dm = inviteLink("https://cmux.com", "conv_dm_01JB8Q3Z5X7Y9K2M4N6P8R0T2V", secret)
    expect(parseInviteLink(dm)?.conversation).toBe("conv_dm_01JB8Q3Z5X7Y9K2M4N6P8R0T2V")
  })

  it("refuses malformed links", () => {
    for (const bad of ["https://cmux.com/i/x01JB8Q3Z5X7Y9K2M4N6P8R0T2V#ABC", "https://cmux.com/i/g01JB#0123456789ABCDEFGHJKMNPQRS", "https://cmux.com/i/g01JB8Q3Z5X7Y9K2M4N6P8R0T2V", "nonsense"])
      expect(parseInviteLink(bad)).toBeNull()
  })
})
