import { describe, expect, it } from "vitest"
import {
  acceptUrlPattern,
  contactId,
  inviteOrigin,
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
    expect(normalizePhone("+1 876 555 0123")).toBe("address.country_not_allowed")
    expect(normalizePhone("+1 809 555 0123")).toBe("address.country_not_allowed")
    expect(normalizePhone("+1 604 555 0123")).toEqual({ channel: "sms", value: "+16045550123" })
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
    const link = inviteLink("staging", conversation, secret)
    expect(link).toBe(`https://console-staging.cmux.dev/i/g01JB8Q3Z5X7Y9K2M4N6P8R0T2V#${secret}`)
    expect(link).toMatch(acceptUrlPattern("staging"))
    expect(link.length).toBeLessThanOrEqual(100)
    expect(parseInviteLink(link)).toEqual({ conversation, secret })
    expect(inviteLink("production", conversation, secret).startsWith("https://console.cmux.dev/i/g")).toBe(true)
    const dm = inviteLink("staging", "conv_dm_01JB8Q3Z5X7Y9K2M4N6P8R0T2V", secret)
    expect(parseInviteLink(dm)?.conversation).toBe("conv_dm_01JB8Q3Z5X7Y9K2M4N6P8R0T2V")
  })

  it("fails closed without a known environment or a bare https origin", () => {
    const secret = newInviteSecret(bytes)
    for (const env of [undefined, "", "development", "preview", "local", "prod"]) expect(() => inviteLink(env, conversation, secret)).toThrow(/no invite accept origin/)
    expect(inviteLink("development", conversation, secret, "https://dev.example.com")).toMatch(acceptUrlPattern("development", "https://dev.example.com"))
    for (const bad of ["http://dev.example.com", "https://dev.example.com/x", "https://dev.example.com/?a=1", "dev.example.com"]) expect(() => inviteOrigin("development", bad)).toThrow()
    expect(() => inviteLink("staging", conversation, "short")).toThrow()
  })

  it("refuses malformed links", () => {
    for (const bad of ["https://cmux.com/i/x01JB8Q3Z5X7Y9K2M4N6P8R0T2V#ABC", "https://cmux.com/i/g01JB#0123456789ABCDEFGHJKMNPQRS", "https://cmux.com/i/g01JB8Q3Z5X7Y9K2M4N6P8R0T2V", "nonsense"])
      expect(parseInviteLink(bad)).toBeNull()
  })
})
