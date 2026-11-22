import { describe, expect, it } from "vitest"
import {
  acceptLocked,
  allowlistFromEnv,
  allowedInvitersFromEnv,
  isAllowedInviter,
  DAY,
  decideSend,
  HOUR,
  isTrustedInviter,
  parseAllowlist,
  recordAcceptFailure,
  takeAddressQuota,
  takeInviterQuota,
  type InviterWindow
} from "../src/invites/index.ts"

const NOW = 1_790_000_000_000
const trusted = { accountCreatedAt: NOW - 30 * DAY, emailVerified: true }

describe("inviter quota", () => {
  it("allows 20 per day, then names when it frees up", () => {
    let window: InviterWindow = { sent: [] }
    for (let i = 0; i < 20; i++) {
      const r = takeInviterQuota(window, trusted, NOW + i * 1000)
      expect(r.ok).toBe(true)
      if (r.ok) window = r.window
    }
    const refused = takeInviterQuota(window, trusted, NOW + 30_000)
    expect(refused).toEqual({ ok: false, code: "invite.rate_limited", retry_at: NOW + DAY, scope: "inviter_day" })
    expect(takeInviterQuota(window, trusted, NOW + DAY + 1).ok).toBe(true)
  })

  it("limits a week to 60", () => {
    const sent = Array.from({ length: 60 }, (_, i) => NOW - 6 * DAY + i * 2 * HOUR)
    const r = takeInviterQuota({ sent }, trusted, NOW)
    expect(r.ok).toBe(false)
    if (!r.ok && r.code === "invite.rate_limited") expect(r.scope).toBe("inviter_week")
  })

  it("gives new or unverified accounts 5 per day and no trust", () => {
    const fresh = { accountCreatedAt: NOW - HOUR, emailVerified: true }
    expect(isTrustedInviter(fresh, NOW)).toBe(false)
    expect(isTrustedInviter({ ...trusted, emailVerified: false }, NOW)).toBe(false)
    const sent = Array.from({ length: 5 }, (_, i) => NOW - i)
    expect(takeInviterQuota({ sent }, fresh, NOW).ok).toBe(false)
    expect(takeInviterQuota({ sent }, { ...fresh, perDayOverride: 50 }, NOW).ok).toBe(true)
  })

  it("blocks reported inviters", () => {
    expect(takeInviterQuota({ sent: [] }, { ...trusted, reported: true }, NOW)).toEqual({ ok: false, code: "invite.blocked", scope: "inviter_reported" })
  })
})

describe("recipient quota", () => {
  it("sends once per inviter per week and attaches repeats", () => {
    const first = takeAddressQuota({ lastByInviter: {} }, "user_a", NOW)
    expect(first).toMatchObject({ ok: true, send: true })
    if (!first.ok) return
    expect(takeAddressQuota(first.window, "user_a", NOW + DAY)).toMatchObject({ ok: true, send: false, reason: "repeat" })
    expect(takeAddressQuota(first.window, "user_a", NOW + 8 * DAY)).toMatchObject({ ok: true, send: true })
  })

  it("allows at most 3 distinct inviters per 30 days", () => {
    const window = { lastByInviter: { user_a: NOW - 10 * DAY, user_b: NOW - 5 * DAY, user_c: NOW - DAY } }
    expect(takeAddressQuota(window, "user_d", NOW)).toEqual({ ok: false, code: "invite.recipient_limited", retry_at: NOW + 20 * DAY })
    expect(takeAddressQuota(window, "user_d", NOW + 21 * DAY)).toMatchObject({ ok: true, send: true })
  })

  it("locks acceptance after 10 failures in an hour", () => {
    let lock = { failures: [] as ReadonlyArray<number> }
    for (let i = 0; i < 9; i++) lock = recordAcceptFailure(lock, NOW + i)
    expect(acceptLocked(lock, NOW + 10)).toBe(false)
    lock = recordAcceptFailure(lock, NOW + 10)
    expect(acceptLocked(lock, NOW + 11)).toBe(true)
    expect(acceptLocked(lock, NOW + HOUR + 11)).toBe(false)
  })
})

describe("environment send policy", () => {
  const allowlist = parseAllowlist("# test list\nemail Allowed@Example.com\nphone (415) 555-0100\n\n")
  const allowed = { channel: "email" as const, value: "allowed@example.com" }
  const stranger = { channel: "email" as const, value: "stranger@example.com" }

  it("parses the allow list and reports positions", () => {
    expect(allowlist.entries).toEqual([allowed, { channel: "sms", value: "+14155550100" }])
    expect(() => parseAllowlist("email ok@example.com\nfax 123")).toThrow(/line 2/)
    expect(() => parseAllowlist("email private-address")).not.toThrow(/private-address/)
  })

  it("reads the Worker's two env lists", () => {
    expect(allowlistFromEnv("Allowed@Example.com, other@example.com", "+1 415 555 0100").entries).toHaveLength(3)
    expect(allowlistFromEnv(undefined, undefined).entries).toHaveLength(0)
    expect(() => allowlistFromEnv("not-an-email", undefined)).toThrow(/entry 1/)
  })

  it("refuses non-production recipients outside the list", () => {
    for (const environment of ["staging", "development", "preview", "local"] as const) {
      expect(decideSend({ environment, allowlist }, stranger, null)).toMatchObject({ send: false, state: "refused_env" })
      expect(decideSend({ environment, allowlist }, allowed, null)).toEqual({ send: true, allowlist_index: 1 })
    }
  })

  it("lets production send to anyone not suppressed", () => {
    expect(decideSend({ environment: "production", allowlist }, stranger, null)).toEqual({ send: true, allowlist_index: 0 })
    expect(decideSend({ environment: "production", allowlist }, stranger, "opted_out")).toMatchObject({ send: false, state: "suppressed" })
  })

  it("staging sends to any recipient for an inviter on the team inviter list, and keeps suppression and the switch", () => {
    for (const environment of ["staging", "development", "preview", "local"] as const) {
      expect(decideSend({ environment, allowlist, trustedInviter: true }, stranger, null)).toEqual({ send: true, allowlist_index: 0 })
      expect(decideSend({ environment, allowlist, trustedInviter: false }, stranger, null)).toMatchObject({ send: false, state: "refused_env" })
      expect(decideSend({ environment, allowlist, trustedInviter: true }, stranger, "reported")).toMatchObject({ send: false, state: "suppressed" })
      expect(decideSend({ environment, allowlist, trustedInviter: true, sendSwitch: "off" }, stranger, null)).toMatchObject({ send: false, state: "disabled" })
    }
  })

  it("reads the inviter list: user ids and verified emails, nothing else", () => {
    const list = allowedInvitersFromEnv("user_abc, Lawrence@Manaflow.ai\naziz@manaflow.ai")
    expect(isAllowedInviter(list, { user: "user_abc" })).toBe(true)
    expect(isAllowedInviter(list, { user: "user_other", email: "lawrence@manaflow.ai" })).toBe(true)
    expect(isAllowedInviter(list, { user: "user_other", email: "AZIZ@manaflow.ai" })).toBe(true)
    expect(isAllowedInviter(list, { user: "user_other" })).toBe(false)
    expect(isAllowedInviter(list, { user: "user_other", email: "mallory@example.com" })).toBe(false)
    expect(isAllowedInviter(allowedInvitersFromEnv(undefined), { user: "user_abc", email: "lawrence@manaflow.ai" })).toBe(false)
    expect(() => allowedInvitersFromEnv("not an entry")).toThrow(/entry 1/)
  })

  it("has a kill switch", () => {
    expect(decideSend({ environment: "production", allowlist, sendSwitch: "OFF" }, allowed, null)).toMatchObject({ send: false, state: "disabled" })
  })
})
