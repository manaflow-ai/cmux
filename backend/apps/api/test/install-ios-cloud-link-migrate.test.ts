import type { ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { iosGrantsToMigrate, userDomain, type UserState } from "../src/domains/user.ts"
import { post, sessionToken } from "./cloud-bind-support.ts"

/**
 * CLOUD-LINK-FOLLOWUPS (2026-10-05, decision 2): iPhone installs registered before cloud-link get it
 * in one idempotent server-side migration (internal install.ios_cloud_link_migrate, run on bind).
 * Only an active ios install whose grant is within the old iPhone default (read, mutate-own) changes.
 */

const OWNER = "user_00000000000000000001"
const jwk = { kty: "EC", crv: "P-256", x: "x".repeat(43), y: "y".repeat(43) }
const inst = (id: string, kind: string, grant: string, revoked: number | null = null) => ({
  id, device: `dev_${id.slice(5)}`, kind, name: id, device_name: id, platform: kind === "ios" ? "ios" : "macos", public_jwk: jwk, thumbprint: id, grant, created_at: 1, revoked_at: revoked
})
const grant = (id: string, grantee: string, op_classes: Array<string>) => ({ id, grantee, op_classes, approval: "none", expires_at: null, revoked_at: null, created_from: "install" })
const state = {
  user: { id: OWNER, stack_user_id: "s", email: null, display_name: "o", personal_team: "team_00000000000000000001" },
  installs: {
    inst_ios_old_000000000000: inst("inst_ios_old_000000000000", "ios", "grant_a"),
    inst_ios_new_000000000000: inst("inst_ios_new_000000000000", "ios", "grant_b"),
    inst_ios_rev_000000000000: inst("inst_ios_rev_000000000000", "ios", "grant_c", 5),
    inst_mac_000000000000000: inst("inst_mac_000000000000000", "mac", "grant_d")
  },
  grants: {
    grant_a: grant("grant_a", "inst_ios_old_000000000000", ["read", "mutate-own"]),
    grant_b: grant("grant_b", "inst_ios_new_000000000000", ["read", "mutate-own", "cloud-link"]),
    grant_c: grant("grant_c", "inst_ios_rev_000000000000", ["read"]),
    grant_d: grant("grant_d", "inst_mac_000000000000000", ["read", "mutate-own"])
  }
} as unknown as UserState
const sys: ReduceContext = { principal: { identity: "system:user", kind: "system" }, now: 9, tx: "t", newId: (p) => `${p}_x` }

describe("old iPhone grants get cloud-link once", () => {
  it("finds only active ios grants within the old default that lack cloud-link", () => {
    expect(iosGrantsToMigrate(state)).toEqual(["grant_a"])
  })

  it("adds cloud-link to them, and a second run changes nothing", () => {
    const r = userDomain.reduce(state, "install.ios_cloud_link_migrate", {}, sys)
    if (!r.ok) throw new Error(r.message)
    const s = r.state as UserState
    expect([...s.grants["grant_a"]!.op_classes].sort()).toEqual(["cloud-link", "mutate-own", "read"])
    expect(s.grants["grant_b"]).toEqual(state.grants["grant_b"])
    expect(s.grants["grant_c"]).toEqual(state.grants["grant_c"])
    expect(s.grants["grant_d"]).toEqual(state.grants["grant_d"])
    expect(iosGrantsToMigrate(s)).toEqual([])
    const again = userDomain.reduce(s, "install.ios_cloud_link_migrate", {}, sys)
    if (!again.ok) throw new Error(again.message)
    expect(again.state).toEqual(s)
  })

  it("is refused for a non-system caller", () => {
    const session: ReduceContext = { ...sys, principal: { identity: `user:${OWNER}`, user: OWNER, kind: "session" } }
    expect(userDomain.reduce(state, "install.ios_cloud_link_migrate", {}, session)).toMatchObject({ ok: false })
  })

  it("runs on the user's object: an old-style iPhone grant has cloud-link at the next request", { timeout: 60_000 }, async () => {
    const session = await sessionToken("ios-cloud-link-migrate")
    await post("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const j = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    // An iPhone grant as it was before cloud-link (read, mutate-own).
    const reg = await post("/v1/ops", session, { op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: j.x, y: j.y }, kind: "ios", name: "p", device_name: "p", platform: "ios", op_classes: ["read", "mutate-own"] }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(reg.body.ok, JSON.stringify(reg.body)).toBe(true)
    const list = await post("/v1/read", session, { op: "install.list", params: {} })
    const i = list.body.value.installs.find((x: any) => x.id === reg.body.value.id)
    expect([...list.body.value.grants.find((g: any) => g.id === i.grant).op_classes].sort()).toEqual(["cloud-link", "mutate-own", "read"])
  })
})
