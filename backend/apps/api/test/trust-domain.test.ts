import type { ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { linkCertMessage, parseLinkCert } from "../src/domains/link-cert.ts"
import { reduceHostGuest } from "../src/domains/team-guests.ts"
import { trustDomain, type TrustState } from "../src/domains/user-trust.ts"
import { offerCode, offerLink, OFFER_CODE } from "../src/pairing-offer.ts"

/** The trust reducer, cert parsing and the offer grammar, without a Durable Object (b6-pairing.md). */

const ctx = (now: number): ReduceContext => ({ principal: { identity: "system:user", kind: "system" }, now, tx: "tx", newId: (p) => `${p}_1` })
const jwk = { kty: "EC", crv: "P-256", x: "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU", y: "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0" }
const key = "A".repeat(43)
const cert = (install: string, user: string, at: number) => ({ purpose: "direct", user, install, key, issued_at: at, expires_at: at + 86_400_000, signature: "s".repeat(86) })
const peer = (install: string, user: string, at: number) => ({ install, user, user_name: "Bea", name: "iPhone", platform: "ios", public_jwk: jwk, cert: cert(install, user, at) })
const apply = (state: TrustState, op: string, params: unknown, now: number) => {
  const r = trustDomain.reduce(state, op, params, ctx(now))
  if (!r.ok) throw new Error(`${op}: ${r.code} ${r.message}`)
  return r.state
}

describe("trust reducer", () => {
  it("drops expired requests on the next write and moves an accepted request to guests", () => {
    const t0 = 1_800_000_000_000
    let s = trustDomain.initial()
    s = apply(s, "trust.request.add", { ...peer("inst_b1", "user_b", t0), offer_id: "o".repeat(43), host: "host_a", host_name: "Studio", team: "team_a", expires_at: t0 + 1000 }, t0)
    s = apply(s, "trust.request.add", { ...peer("inst_b2", "user_b", t0), offer_id: "p".repeat(43), host: "host_a", host_name: "Studio", team: "team_a", expires_at: t0 + 60_000 }, t0)
    expect(Object.keys(s.requests)).toHaveLength(2)
    s = apply(s, "trust.guest.add", { ...peer("inst_b2", "user_b", t0), offer_id: "p".repeat(43), host: "host_a", team: "team_a" }, t0 + 2000)
    expect(s.requests).toEqual({})
    expect(Object.keys(s.guests)).toEqual(["host_a/inst_b2"])
  })

  it("refuses a request whose cert is not the device's direct cert, and an unknown op", () => {
    const t0 = 1_800_000_000_000
    const bad = { ...peer("inst_b1", "user_b", t0), cert: cert("inst_other", "user_b", t0), offer_id: "o".repeat(43), host: "h_1", host_name: "x", team: "team_a", expires_at: t0 + 1000 }
    expect(trustDomain.reduce(trustDomain.initial(), "trust.request.add", bad, ctx(t0)).ok).toBe(false)
    expect(trustDomain.reduce(trustDomain.initial(), "trust.nope", {}, ctx(t0)).ok).toBe(false)
  })

  it("only system principals of a UserDO write", () => {
    const s = trustDomain.initial()
    expect(trustDomain.authorize!(s, "trust.key.set", {}, { identity: "inst_1", kind: "install" })).toMatchObject({ code: "auth.forbidden" })
    expect(trustDomain.authorize!(s, "trust.key.set", {}, { identity: "system:team:t", kind: "system" })).toMatchObject({ code: "auth.forbidden" })
    expect(trustDomain.authorize!(s, "trust.key.set", {}, { identity: "system:user:user_b", kind: "system" })).toBeUndefined()
  })
})

describe("link certs and offers", () => {
  it("builds the canonical message the Swift side signs", () => {
    expect(linkCertMessage("test", { user: "user_a", install: "inst_a", purpose: "direct", key, issued_at: 1, expires_at: 2 })).toBe(`cmux-link-cert/1\ntest\nuser_a\ninst_a\ndirect\n${key}\n1\n2`)
    expect(parseLinkCert({ ...cert("inst_a", "user_a", 10), expires_at: 10 })).toMatch(/lifetime/)
  })

  it("mints 26-symbol codes and percent-encoded links", () => {
    expect(offerCode(new Uint8Array(16))).toBe("0".repeat(26))
    expect(offerCode(new Uint8Array(16).fill(255))).toBe("7" + "Z".repeat(25))
    expect(OFFER_CODE.test(offerCode())).toBe(true)
    expect(offerLink("0".repeat(26), { host: "host_a", team: "team_a", host_key: key, expires_at: 1_800_000_000_000, name: "Bea's Mac+Pro" })).toBe(
      `cmux://pair/1?o=${"0".repeat(26)}&h=host_a&t=team_a&k=${key}&e=1800000000&n=Bea's%20Mac%2BPro`
    )
  })

  it("caps guests per host and removes them", () => {
    const t0 = 1
    let s: { host_guests?: Record<string, Record<string, { user: string; offer_id: string; at: number }>> } = {}
    const r = reduceHostGuest(s, "host.guest.set", { host: "host_a", install: "inst_b", user: "user_b", offer_id: "x" }, ctx(t0), () => true)
    expect(r.ok).toBe(true)
    s = (r as { state: typeof s }).state
    expect(reduceHostGuest(s, "host.guest.set", { host: "host_z", install: "inst_b", user: "user_b", offer_id: "x" }, ctx(t0), () => false)).toMatchObject({ ok: false, code: "selector.not_found" })
    const removed = reduceHostGuest(s, "host.guest.remove", { host: "host_a", install: "inst_b" }, ctx(t0), () => true)
    expect((removed as { state: typeof s }).state.host_guests).toEqual({})
  })
})
