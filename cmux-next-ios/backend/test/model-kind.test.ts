import { evictDurableObject, runInDurableObject } from "cloudflare:test"
import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { memoryStore, modelKind } from "../src/store.ts"
import { type TeamHub, userHubName } from "../src/team-hub.ts"
import { call, connect, DEV_PROJECT, register, token } from "./helpers.ts"

const hubOf = (owner: string) => {
  const ns = (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB
  return ns.get(ns.idFromName(userHubName(owner)))
}

describe("device model kind", () => {
  it("accepts forward-compatible names and ignores malformed strings", () => {
    for (const kind of ["macbook", "mac-mini", "mac-studio", "iphone", "ipad", "future-model", "a".repeat(32)]) expect(modelKind(kind)).toBe(kind)
    for (const kind of [undefined, null, 4, "", "MacBook", "mac mini", "mac--mini", "-mac", "mac-", "a".repeat(33)]) expect(modelKind(kind)).toBeUndefined()
  })

  it("keeps admission kind separate and returns models on every REST device surface", async () => {
    const owner = "model-rest"
    const t = await token(owner)
    const teamId = `personal-${owner}`
    const deviceId = crypto.randomUUID()
    const body = { deviceId, kind: "mac", name: "Mac", teamId }
    const first = await call("POST", "/v1/devices", t, { ...body, modelKind: "mac-mini" })
    expect(first.status).toBe(200)
    expect(first.json.device).toMatchObject({ kind: "mac", modelKind: "mac-mini" })
    for (const extra of [{}, { modelKind: null }, { modelKind: "INVALID" }, { modelKind: "" }]) {
      const again = await call("POST", "/v1/devices", t, { ...body, ...extra })
      expect(again.status).toBe(200)
      expect(again.json.device.modelKind).toBe("mac-mini")
    }
    for (const path of [`/v1/teams/${teamId}/macs`, "/v1/me/macs"]) {
      expect((await call("GET", path, t)).json.macs).toEqual([expect.objectContaining({ deviceId, kind: "mac-mini" })])
    }
    const phone = await call("POST", "/v1/devices", t, { deviceId: crypto.randomUUID(), kind: "phone", name: "Tablet", teamId, modelKind: "ipad" })
    expect(phone.status).toBe(200)
    expect(phone.json.device).toMatchObject({ kind: "phone", modelKind: "ipad" })
    expect((await call("GET", "/v1/me/devices", t)).json.devices).toEqual(expect.arrayContaining([
      expect.objectContaining({ deviceId, kind: "mac", modelKind: "mac-mini" }),
      expect.objectContaining({ kind: "phone", modelKind: "ipad" })
    ]))
    for (const modelKind of [3, false, {}, []]) expect((await call("POST", "/v1/devices", t, { ...body, modelKind })).status).toBe(400)
    // Model metadata cannot promote a phone into a host or take another owner's device.
    expect((await call("GET", "/v1/me/macs", t)).json.macs).toHaveLength(1)
    expect((await call("POST", "/v1/devices", await token("model-other"), { ...body, teamId: "personal-model-other", modelKind: "mac-pro" })).status).toBe(403)
  })

  it("broadcasts a model-only change and preserves it across reconnects", async () => {
    const owner = "model-live"
    const teamId = `personal-${owner}`
    const t = await token(owner)
    const deviceId = await register(t, "mac", teamId)
    const phoneId = await register(t, "phone", teamId)
    const phone = await connect(t, teamId, phoneId)
    const mac = await connect(t, teamId, deviceId)
    await phone.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === deviceId && f.mac.online))
    const before = (await call("GET", "/v1/me/devices", t)).json.devices.find((d: { deviceId: string }) => d.deviceId === deviceId)
    expect((await call("POST", "/v1/devices", t, { deviceId, kind: "mac", name: before.name, teamId, modelKind: "mac-studio" })).status).toBe(200)
    await phone.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === deviceId && f.mac.kind === "mac-studio"))
    const reconnected = await connect(t, teamId, deviceId)
    await reconnected.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(reconnected.frames.find((f) => f.type === "hello").macs).toEqual([expect.objectContaining({ deviceId, kind: "mac-studio" })])
    for (const s of [phone, mac, reconnected]) s.ws.close()
  })

  it("seeds offline models without an admission row and admits legacy stored hosts", async () => {
    const owner = "model-seed"
    const teamId = `personal-${owner}`
    const t = await token(owner)
    const store = memoryStore()
    const deviceId = crypto.randomUUID()
    const legacyId = crypto.randomUUID()
    for (const [id, model] of [[deviceId, "imac"], [legacyId, undefined]] as const) {
      await store.upsertDevice({ deviceId: id, ownerUserId: owner, teamId, kind: "mac", name: "Mac", wgPublicKey: null, modelKind: model })
    }
    const phoneId = await register(t, "phone", teamId)
    const phone = await connect(t, teamId, phoneId)
    await phone.until((s) => s.frames.some((f) => f.type === "hello"))
    const macs = phone.frames.find((f) => f.type === "hello").macs
    expect(macs).toEqual(expect.arrayContaining([
      expect.objectContaining({ deviceId, kind: "imac", online: false }),
      expect.objectContaining({ deviceId: legacyId, kind: null, online: false })
    ]))
    const mac = await connect(t, teamId, deviceId)
    await mac.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(mac.frames.find((f) => f.type === "hello").macs).toEqual(expect.arrayContaining([expect.objectContaining({ deviceId, kind: "imac" })]))
    for (const s of [phone, mac]) s.ws.close()
  })

  it("migrates legacy SQLite columns without inventing a model from the platform", async () => {
    const owner = "model-migrate"
    const deviceId = crypto.randomUUID()
    const hub = hubOf(owner)
    await runInDurableObject(hub, (_hub, state) => {
      const sql = state.storage.sql
      sql.exec("ALTER TABLE macs DROP COLUMN model_kind")
      sql.exec("ALTER TABLE devices DROP COLUMN model_kind")
      sql.exec("INSERT INTO devices (device_id, owner_key, kind, name, team_id) VALUES (?, ?, 'mac', 'Mac', ?)", deviceId, owner, `personal-${owner}`)
      sql.exec("INSERT INTO macs (device_id, name, owner_user_id, owner_project_id, team_id) VALUES (?, 'Mac', ?, ?, ?)", deviceId, owner, DEV_PROJECT, `personal-${owner}`)
    })
    // A deployment wakes the existing object's SQL storage under the new schema.
    await evictDurableObject(hub)
    expect(await hub.macs(owner)).toEqual([expect.objectContaining({ deviceId, kind: null })])
    await hub.register({ deviceId, ownerKey: owner, kind: "mac", name: "Mac", teamId: `personal-${owner}`, userId: owner, projectId: DEV_PROJECT, modelKind: "macbook" })
    await hub.register({ deviceId, ownerKey: owner, kind: "mac", name: "Mac", teamId: `personal-${owner}`, userId: owner, projectId: DEV_PROJECT })
    expect(await hub.macs(owner)).toEqual([expect.objectContaining({ deviceId, kind: "macbook" })])
    await runInDurableObject(hub, (_hub, state) => {
      expect(state.storage.sql.exec<{ model_kind: string }>("SELECT model_kind FROM devices WHERE device_id = ?", deviceId).toArray()[0]?.model_kind).toBe("macbook")
    })
  })
})
