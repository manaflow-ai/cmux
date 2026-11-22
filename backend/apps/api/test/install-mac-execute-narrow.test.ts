import type { ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { macGrantsToNarrow, userDomain, type UserState } from "../src/domains/user.ts"
import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { post, sessionToken } from "./cloud-bind-support.ts"

/**
 * cx-wb5.64: Mac installs registered before the mac grant cap (e9d25623248e) got the old default
 * (read, mutate-own, mutate-shared, execute). One idempotent server-side migration (internal
 * install.mac_execute_narrow, run on bind) drops execute from their grants and keeps every other
 * class. No class is added, and nothing but an active mac install's grant changes.
 */

const OWNER = "user_00000000000000000001"
const jwk = { kty: "EC", crv: "P-256", x: "x".repeat(43), y: "y".repeat(43) }
const inst = (id: string, kind: string, grant: string, revoked: number | null = null) => ({
  id, device: `dev_${id.slice(5)}`, kind, name: id, device_name: id, platform: kind === "ios" ? "ios" : "macos", public_jwk: jwk, thumbprint: id, grant, created_at: 1, revoked_at: revoked
})
const grant = (id: string, grantee: string, op_classes: Array<string>, revoked: number | null = null) => ({ id, grantee, op_classes, approval: "none", expires_at: null, revoked_at: revoked, created_from: "install" })
const OLD_MAC = ["read", "mutate-own", "mutate-shared", "execute"]
const state = {
  user: { id: OWNER, stack_user_id: "s", email: null, display_name: "o", personal_team: "team_00000000000000000001" },
  installs: {
    inst_mac_old_000000000000: inst("inst_mac_old_000000000000", "mac", "grant_a"),
    inst_mac_new_000000000000: inst("inst_mac_new_000000000000", "mac", "grant_b"),
    inst_mac_rev_000000000000: inst("inst_mac_rev_000000000000", "mac", "grant_c", 5),
    inst_cli_000000000000000: inst("inst_cli_000000000000000", "cli", "grant_d"),
    inst_mac_link_00000000000: inst("inst_mac_link_00000000000", "mac", "grant_e")
  },
  grants: {
    grant_a: grant("grant_a", "inst_mac_old_000000000000", OLD_MAC),
    grant_b: grant("grant_b", "inst_mac_new_000000000000", ["read", "mutate-own", "mutate-shared", "cloud-link"]),
    grant_c: grant("grant_c", "inst_mac_rev_000000000000", OLD_MAC),
    grant_d: grant("grant_d", "inst_cli_000000000000000", OLD_MAC),
    grant_e: grant("grant_e", "inst_mac_link_00000000000", ["read", "cloud-link", "execute"])
  }
} as unknown as UserState
const sys: ReduceContext = { principal: { identity: "system:user", kind: "system" }, now: 9, tx: "t", newId: (p) => `${p}_x` }

describe("old Mac grants lose execute once", () => {
  it("finds only active mac grants that still carry execute", () => {
    expect(macGrantsToNarrow(state).sort()).toEqual(["grant_a", "grant_e"])
  })

  it("drops execute and keeps every other class, and a second run changes nothing", () => {
    const r = userDomain.reduce(state, "install.mac_execute_narrow", {}, sys)
    if (!r.ok) throw new Error(r.message)
    const s = r.state as UserState
    expect([...s.grants["grant_a"]!.op_classes].sort()).toEqual(["mutate-own", "mutate-shared", "read"])
    expect([...s.grants["grant_e"]!.op_classes].sort()).toEqual(["cloud-link", "read"])
    expect(s.grants["grant_b"]).toEqual(state.grants["grant_b"])
    expect(s.grants["grant_c"]).toEqual(state.grants["grant_c"])
    expect(s.grants["grant_d"]).toEqual(state.grants["grant_d"])
    expect(r.value).toEqual({ narrowed: 2 })
    expect(macGrantsToNarrow(s)).toEqual([])
    const again = userDomain.reduce(s, "install.mac_execute_narrow", {}, sys)
    if (!again.ok) throw new Error(again.message)
    expect(again.state).toEqual(s)
  })

  it("runs once per user: after the done flag, a mac grant with execute is left alone", () => {
    const r = userDomain.reduce(state, "install.mac_execute_narrow", {}, sys)
    if (!r.ok) throw new Error(r.message)
    const done = r.state as UserState
    expect(done.migrations?.mac_execute_narrow).toBe(true)
    const later = { ...done, grants: { ...done.grants, grant_a: grant("grant_a", "inst_mac_old_000000000000", OLD_MAC) } } as unknown as UserState
    expect(macGrantsToNarrow(later)).toEqual([])
  })

  it("is refused for a non-system caller", () => {
    const session: ReduceContext = { ...sys, principal: { identity: `user:${OWNER}`, user: OWNER, kind: "session" } }
    expect(userDomain.reduce(state, "install.mac_execute_narrow", {}, session)).toMatchObject({ ok: false })
  })

  it("the per-request grant check (installGrant) narrows an old Mac grant first, so execute is gone at once", { timeout: 60_000 }, async () => {
    const session = await sessionToken("mac-execute-narrow-grant-path")
    const user = (await post("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })).body.value.id as string
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const j = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const reg = await post("/v1/ops", session, { op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: j.x, y: j.y }, kind: "mac", name: "cmux", device_name: "m", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(reg.body.ok, JSON.stringify(reg.body)).toBe(true)
    const install = reg.body.value.id as string
    const grantId = reg.body.value.grant as string
    const ns = (env as unknown as { USER_DO: DurableObjectNamespace }).USER_DO
    const stub = ns.get(ns.idFromName(user))
    // Give the grant the pre-cap default (in memory only) and clear the done flag, as on a user from before the cap.
    await (runInDurableObject as unknown as (s: unknown, f: (i: any) => Promise<void>) => Promise<void>)(stub, async (i) => {
      const st = i.boundEngine.currentState
      st.grants[grantId] = { ...st.grants[grantId], op_classes: OLD_MAC }
      if (st.migrations) delete st.migrations.mac_execute_narrow
    })
    const r = await (stub as unknown as { installGrant(e: string, i: string, g: string): Promise<{ ok: boolean; op_classes?: ReadonlyArray<string> }> }).installGrant(user, install, grantId)
    expect(r.ok).toBe(true)
    expect([...(r.op_classes ?? [])].sort()).toEqual(["mutate-own", "mutate-shared", "read"])
  })
})
