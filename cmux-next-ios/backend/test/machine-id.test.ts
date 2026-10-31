import { runInDurableObject } from "cloudflare:test"
import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { userHubName, type TeamHub } from "../src/team-hub.ts"
import { call, connect, token } from "./helpers.ts"

const hubOf = (owner: string) => {
  const ns = (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB
  return ns.get(ns.idFromName(userHubName(owner)))
}

// A Mac's machine id (PROTOCOL.md "Devices"): every cmux build on one computer registers its own device, and
// says which computer it runs on, so the phone lists that computer once. A name is never an identity.
const MACHINE_A = "a1".repeat(16)
const MACHINE_B = "b2".repeat(16)

const registerMac = async (tok: string, teamId: string, name: string, extra: Record<string, unknown> = {}) => {
  const deviceId = crypto.randomUUID()
  const r = await call("POST", "/v1/devices", tok, { deviceId, kind: "mac", name, teamId, ...extra })
  expect(r.status).toBe(200)
  return { deviceId, device: r.json.device }
}

describe("Mac machine id", () => {
  it("stores the machine id and lists it with every Mac route", async () => {
    const t = await token("mid-ann")
    const { deviceId, device } = await registerMac(t, "personal-mid-ann", "Ann's MacBook Pro", { machineId: MACHINE_A })
    expect(device).toMatchObject({ deviceId, machineId: MACHINE_A })
    const team = await call("GET", "/v1/teams/personal-mid-ann/macs", t)
    expect(team.json.macs).toEqual([expect.objectContaining({ deviceId, machineId: MACHINE_A })])
    const mine = await call("GET", "/v1/me/macs", t)
    expect(mine.json.macs).toEqual([expect.objectContaining({ deviceId, machineId: MACHINE_A })])
    const all = await call("GET", "/v1/me/devices", t)
    expect(all.json.devices).toEqual([expect.objectContaining({ deviceId, machineId: MACHINE_A })])
  })

  it("keeps two same-named Macs on different machines apart, and two builds on one machine together", async () => {
    const t = await token("mid-bob")
    const nightly = await registerMac(t, "personal-mid-bob", "Bob's Mac", { machineId: MACHINE_A })
    const dev = await registerMac(t, "personal-mid-bob", "Bob's Mac", { machineId: MACHINE_A })
    const other = await registerMac(t, "personal-mid-bob", "Bob's Mac", { machineId: MACHINE_B })
    const macs = (await call("GET", "/v1/teams/personal-mid-bob/macs", t)).json.macs as Array<{ deviceId: string; machineId: string | null }>
    // Each build stays its own device: its own id, identity key and pairing.
    expect(macs.map((m) => m.deviceId).sort()).toEqual([nightly.deviceId, dev.deviceId, other.deviceId].sort())
    const machine = new Map(macs.map((m) => [m.deviceId, m.machineId]))
    expect(machine.get(nightly.deviceId)).toBe(MACHINE_A)
    expect(machine.get(dev.deviceId)).toBe(MACHINE_A)
    expect(machine.get(other.deviceId)).toBe(MACHINE_B)
  })

  it("refuses a machine id that is not 32 lowercase hex digits, and a phone's", async () => {
    const t = await token("mid-cat")
    for (const machineId of ["", "A1".repeat(16), "a1".repeat(15), "a1".repeat(17), "zz".repeat(16), 7]) {
      const r = await call("POST", "/v1/devices", t, { deviceId: crypto.randomUUID(), kind: "mac", name: "Mac", teamId: "personal-mid-cat", machineId })
      expect(r.status).toBe(400)
    }
    const phone = await call("POST", "/v1/devices", t, { deviceId: crypto.randomUUID(), kind: "phone", name: "iPhone", teamId: "personal-mid-cat", machineId: MACHINE_A })
    expect(phone.status).toBe(400)
  })

  it("a registration without a machine id keeps the stored one (an older hostd of the same build)", async () => {
    const t = await token("mid-dan")
    const { deviceId } = await registerMac(t, "personal-mid-dan", "Dan's Mac", { machineId: MACHINE_A })
    const again = await call("POST", "/v1/devices", t, { deviceId, kind: "mac", name: "Dan's Mac", teamId: "personal-mid-dan" })
    expect(again.json.device.machineId).toBe(MACHINE_A)
    const moved = await call("POST", "/v1/devices", t, { deviceId, kind: "mac", name: "Dan's Mac", teamId: "personal-mid-dan", machineId: MACHINE_B })
    expect(moved.json.device.machineId).toBe(MACHINE_B)
  })

  it("claims the owner's older builds on the same Mac that never sent a machine id", async () => {
    const t = await token("mid-eve")
    // The record a deleted build left: registered before machine ids, offline for good.
    const old = await registerMac(t, "personal-mid-eve", "Eve's MacBook Pro")
    const claimed = await registerMac(t, "personal-mid-eve", "Eve's MacBook Pro", { machineId: MACHINE_B })
    // Another owner's Mac is never claimed, nor is a Mac that reported its own machine id.
    const theirs = await registerMac(await token("mid-fay"), "personal-mid-fay", "Fay's Mac")
    const phone = await call("POST", "/v1/devices", t, { deviceId: crypto.randomUUID(), kind: "phone", name: "iPhone", teamId: "personal-mid-eve" })
    const phoneId = phone.json.device.deviceId as string
    const nightly = await registerMac(t, "personal-mid-eve", "Eve's MacBook Pro", {
      machineId: MACHINE_A,
      siblingDeviceIds: [old.deviceId, claimed.deviceId, theirs.deviceId, phoneId, crypto.randomUUID()]
    })
    const macs = (await call("GET", "/v1/teams/personal-mid-eve/macs", t)).json.macs as Array<{ deviceId: string; machineId: string | null }>
    const machine = new Map(macs.map((m) => [m.deviceId, m.machineId]))
    expect(machine.get(nightly.deviceId)).toBe(MACHINE_A)
    expect(machine.get(old.deviceId)).toBe(MACHINE_A)
    expect(machine.get(claimed.deviceId)).toBe(MACHINE_B)
    const fay = (await call("GET", "/v1/teams/personal-mid-fay/macs", await token("mid-fay"))).json.macs
    expect(fay).toEqual([expect.objectContaining({ deviceId: theirs.deviceId })])
    // A Mac with no machine id keeps the older wire shape: no key at all.
    expect("machineId" in fay[0]).toBe(false)
    const devices = (await call("GET", "/v1/me/devices", t)).json.devices as Array<{ deviceId: string; machineId: string | null }>
    expect(devices.find((d) => d.deviceId === phoneId)?.machineId ?? null).toBeNull()
  })

  it("refuses a malformed sibling list", async () => {
    const t = await token("mid-gus")
    for (const siblingDeviceIds of ["x", ["not-a-uuid"], Array.from({ length: 17 }, () => crypto.randomUUID())]) {
      const r = await call("POST", "/v1/devices", t, {
        deviceId: crypto.randomUUID(), kind: "mac", name: "Mac", teamId: "personal-mid-gus", machineId: MACHINE_A, siblingDeviceIds
      })
      expect(r.status).toBe(400)
    }
  })

  it("hello and presence frames carry the machine id, also for a claimed older build", async () => {
    const t = await token("mid-hal")
    const old = await registerMac(t, "personal-mid-hal", "Hal's Mac")
    const phone = crypto.randomUUID()
    expect((await call("POST", "/v1/devices", t, { deviceId: phone, kind: "phone", name: "iPhone", teamId: "personal-mid-hal" })).status).toBe(200)
    const p = await connect(t, "personal-mid-hal", phone)
    await p.until((s) => s.frames.some((f) => f.type === "hello"))
    const mac = await registerMac(t, "personal-mid-hal", "Hal's Mac", { machineId: MACHINE_A, siblingDeviceIds: [old.deviceId] })
    const m = await connect(t, "personal-mid-hal", mac.deviceId)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac.deviceId && f.mac.online))
    expect(p.frames.find((f) => f.type === "presence" && f.mac.deviceId === mac.deviceId)!.mac.machineId).toBe(MACHINE_A)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === old.deviceId && f.mac.machineId === MACHINE_A))
    const late = await connect(t, "personal-mid-hal", phone)
    await late.until((s) => s.frames.some((f) => f.type === "hello"))
    const hello = late.frames.find((f) => f.type === "hello")!
    expect(hello.macs).toEqual(expect.arrayContaining([
      expect.objectContaining({ deviceId: mac.deviceId, machineId: MACHINE_A }),
      expect.objectContaining({ deviceId: old.deviceId, machineId: MACHINE_A })
    ]))
    for (const s of [p, m, late]) s.ws.close()
  })

  it("a hub that missed a claim catches up at the next registration", async () => {
    const t = await token("mid-ida")
    const old = await registerMac(t, "personal-mid-ida", "Ida's Mac")
    const body = { kind: "mac", name: "Ida's Mac", teamId: "personal-mid-ida", machineId: MACHINE_A, siblingDeviceIds: [old.deviceId] }
    const mac = await registerMac(t, "personal-mid-ida", "Ida's Mac", { machineId: MACHINE_A, siblingDeviceIds: [old.deviceId] })
    // The hub call after the database claim failed: the hub still has no machine id for the old build.
    await runInDurableObject(hubOf("mid-ida"), (_hub, state) => {
      state.storage.sql.exec("UPDATE macs SET machine_id = NULL WHERE device_id = ?", old.deviceId)
    })
    expect((await call("POST", "/v1/devices", t, { ...body, deviceId: mac.deviceId })).status).toBe(200)
    const phone = crypto.randomUUID()
    expect((await call("POST", "/v1/devices", t, { deviceId: phone, kind: "phone", name: "iPhone", teamId: "personal-mid-ida" })).status).toBe(200)
    const p = await connect(t, "personal-mid-ida", phone)
    await p.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(p.frames.find((f) => f.type === "hello")!.macs).toEqual(
      expect.arrayContaining([expect.objectContaining({ deviceId: old.deviceId, machineId: MACHINE_A })])
    )
    p.ws.close()
  })
})
