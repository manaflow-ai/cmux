import { afterAll, beforeAll, beforeEach, describe, expect, it } from "bun:test"
import mysql from "mysql2/promise"
import { mysqlStore } from "../../../cmux-next-ios/backend/src/store-mysql.ts"
import type { Store } from "../../../cmux-next-ios/backend/src/store-types.ts"

/**
 * cmux-mobile-api's store on cmux-next-vitess (drizzle-mysql 0002_mobile): the same contract the
 * Postgres store kept (cmux-next-ios/backend/src/store-types.ts), run against a migrated MySQL.
 */
const url = process.env.MYSQL_URL
const run = url ? describe : describe.skip

const A = "user-a"
const B = "proj2:user-b"
const mac1 = "11111111-1111-4111-8111-111111111111"
const mac2 = "22222222-2222-4222-8222-222222222222"
const phone = "33333333-3333-4333-8333-333333333333"
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/

run("cmux-mobile-api store on MySQL", () => {
  let conn: mysql.Connection
  let store: Store
  beforeAll(async () => {
    conn = await mysql.createConnection({ uri: url!, timezone: "Z", dateStrings: true })
    store = await mysqlStore(conn)
  })
  // Only this test's owners: the suite may run against a shared Vitess branch that holds real rows.
  const clean = async () => {
    await conn.query("DELETE FROM mobile_push_tokens WHERE owner_user_id IN (?, ?)", [A, B])
    await conn.query("DELETE FROM mobile_team_prefs WHERE user_id IN (?, ?)", [A, B])
    await conn.query("DELETE FROM mobile_devices WHERE owner_user_id IN (?, ?)", [A, B])
  }
  beforeEach(clean)
  afterAll(async () => {
    await clean()
    await conn.end()
  })

  it("registers, moves and refuses another owner's device", async () => {
    const first = await store.upsertDevice({ deviceId: mac1.toUpperCase(), ownerUserId: A, teamId: "t1", kind: "mac", name: "Studio", wgPublicKey: "wg1" })
    if (first === "not_owner") throw new Error("expected a device")
    expect(first.previousTeamId).toBeNull()
    expect(first.device).toMatchObject({ deviceId: mac1, ownerUserId: A, teamId: "t1", kind: "mac", name: "Studio", wgPublicKey: "wg1", machineId: null, lastSeenAt: null })
    expect(first.device.createdAt).toMatch(ISO)

    const moved = await store.upsertDevice({ deviceId: mac1, ownerUserId: A, teamId: "t2", kind: "mac", name: "Studio 2", wgPublicKey: null, machineId: "m1" })
    if (moved === "not_owner") throw new Error("expected a device")
    expect(moved.previousTeamId).toBe("t1")
    expect(moved.device).toMatchObject({ teamId: "t2", name: "Studio 2", wgPublicKey: null, machineId: "m1" })

    const kept = await store.upsertDevice({ deviceId: mac1, ownerUserId: A, teamId: "t2", kind: "mac", name: "Studio 2", wgPublicKey: null })
    if (kept === "not_owner") throw new Error("expected a device")
    expect(kept.previousTeamId).toBeNull()
    expect(kept.device.machineId).toBe("m1")

    expect(await store.upsertDevice({ deviceId: mac1, ownerUserId: B, teamId: "t9", kind: "mac", name: "theirs", wgPublicKey: null })).toBe("not_owner")
    expect((await store.getDevice(mac1))?.ownerUserId).toBe(A)
    expect(await store.getDevice(mac2)).toBeUndefined()
  })

  it("claims sibling Macs that have no machine id yet", async () => {
    await store.upsertDevice({ deviceId: mac1, ownerUserId: A, teamId: "t1", kind: "mac", name: "a", wgPublicKey: null, machineId: "m1" })
    await store.upsertDevice({ deviceId: mac2, ownerUserId: A, teamId: "t1", kind: "mac", name: "b", wgPublicKey: null })
    await store.upsertDevice({ deviceId: phone, ownerUserId: A, teamId: "t1", kind: "phone", name: "p", wgPublicKey: null })
    expect(await store.claimSiblings(A, "m1", [])).toEqual([])
    expect((await store.claimSiblings(A, "m1", [mac1, mac2, phone])).sort()).toEqual([mac1, mac2])
    expect((await store.getDevice(mac2))?.machineId).toBe("m1")
    expect((await store.getDevice(phone))?.machineId).toBeNull()
    expect(await store.claimSiblings(B, "m1", [mac1])).toEqual([])
  })

  it("lists an owner's Macs and devices with push state", async () => {
    await store.upsertDevice({ deviceId: mac2, ownerUserId: A, teamId: "t1", kind: "mac", name: "Zed", wgPublicKey: null })
    await store.upsertDevice({ deviceId: mac1, ownerUserId: A, teamId: "t2", kind: "mac", name: "Alpha", wgPublicKey: null })
    await store.upsertDevice({ deviceId: phone, ownerUserId: A, teamId: "t1", kind: "phone", name: "iPhone", wgPublicKey: null })
    await store.setPush({ deviceId: phone, ownerUserId: A, token: "tok1", environment: "production", topic: "dev.cmux.mobile.prod", kinds: ["question", "chief"], mutedMacs: [], previews: true })
    expect((await store.listOwnerMacs(A)).map((d) => d.name)).toEqual(["Alpha", "Zed"])
    expect((await store.listOwnerDevices(A)).map((d) => [d.kind, d.name, d.push])).toEqual([["mac", "Alpha", false], ["mac", "Zed", false], ["phone", "iPhone", true]])
    expect(await store.listOwnerMacs(B)).toEqual([])
  })

  it("keeps push registrations and drops gone tokens", async () => {
    const reg = await store.setPush({ deviceId: phone, ownerUserId: A, token: "tok1", environment: "sandbox", topic: "dev.cmux.mobile", kinds: ["question", "bogus" as never], mutedMacs: [mac1, mac2], previews: false })
    expect(reg).toMatchObject({ deviceId: phone, token: "tok1", environment: "sandbox", kinds: ["question"], mutedMacs: [mac1, mac2], previews: false })
    expect(reg.updatedAt).toMatch(ISO)
    const again = await store.setPush({ deviceId: phone, ownerUserId: A, token: "tok2", environment: "production", topic: "dev.cmux.mobile.prod", kinds: ["completed"], mutedMacs: [], previews: true })
    expect(again).toMatchObject({ token: "tok2", environment: "production", kinds: ["completed"], mutedMacs: [], previews: true })
    expect((await store.listOwnerPush(A)).map((p) => p.token)).toEqual(["tok2"])
    await store.dropPushTokens(["tok2"])
    expect(await store.listOwnerPush(A)).toEqual([])
    await store.setPush({ deviceId: phone, ownerUserId: A, token: "tok3", environment: "production", topic: "t", kinds: ["failed"], mutedMacs: [], previews: true })
    await store.deletePush(phone)
    expect(await store.listOwnerPush(A)).toEqual([])
  })

  it("deletes a device with its token, and a whole owner", async () => {
    await store.upsertDevice({ deviceId: phone, ownerUserId: A, teamId: "t1", kind: "phone", name: "p", wgPublicKey: null })
    await store.setPush({ deviceId: phone, ownerUserId: A, token: "tok1", environment: "production", topic: "t", kinds: ["question"], mutedMacs: [], previews: true })
    expect(await store.deleteDevice(phone, B)).toBe("not_owner")
    expect(await store.deleteDevice(mac2, A)).toBeUndefined()
    expect((await store.deleteDevice(phone, A)) as { deviceId: string }).toMatchObject({ deviceId: phone })
    expect(await store.listOwnerPush(A)).toEqual([])

    await store.upsertDevice({ deviceId: mac1, ownerUserId: A, teamId: "t1", kind: "mac", name: "a", wgPublicKey: null })
    await store.upsertDevice({ deviceId: mac2, ownerUserId: B, teamId: "t1", kind: "mac", name: "b", wgPublicKey: null })
    await store.putPrefs(A, "t1", { color: "#fff" })
    expect((await store.deleteOwner(A)).map((d) => d.deviceId)).toEqual([mac1])
    expect(await store.getPrefs(A, "t1")).toEqual({ color: null, emoji: null, transparent: false })
    expect((await store.getDevice(mac2))?.ownerUserId).toBe(B)
  })

  it("merges team prefs field by field", async () => {
    expect(await store.getPrefs(A, "t1")).toEqual({ color: null, emoji: null, transparent: false })
    expect(await store.putPrefs(A, "t1", { color: "#123456" })).toEqual({ color: "#123456", emoji: null, transparent: false })
    expect(await store.putPrefs(A, "t1", { emoji: "🦊", transparent: true })).toEqual({ color: "#123456", emoji: "🦊", transparent: true })
    expect(await store.putPrefs(A, "t1", { emoji: "" })).toEqual({ color: "#123456", emoji: "", transparent: false })
    expect(await store.getPrefs(A, "t1")).toEqual({ color: "#123456", emoji: "", transparent: false })
  })

  it("names every team scope with its Stack project", async () => {
    await store.upsertDevice({ deviceId: mac1, ownerUserId: A, teamId: "scope-t1", kind: "mac", name: "a", wgPublicKey: null })
    await store.upsertDevice({ deviceId: mac2, ownerUserId: B, teamId: "scope-t2", kind: "mac", name: "b", wgPublicKey: null })
    await store.putPrefs(A, "scope-t3", { color: "#000" })
    const scopes = (await store.listTeamScopes()).filter((x) => x.teamId.startsWith("scope-")).sort((x, y) => x.teamId.localeCompare(y.teamId))
    expect(scopes).toEqual([
      { project: null, teamId: "scope-t1", deviceIds: [mac1] },
      { project: "proj2", teamId: "scope-t2", deviceIds: [mac2] },
      { project: null, teamId: "scope-t3", deviceIds: [] }
    ])
  })
})
