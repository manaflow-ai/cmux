import { describe, expect, it, vi } from "vitest"
import { LOCAL_COMPUTER_CAP, reserveLocalComputer } from "../src/chief-brain-cc/local-computer.ts"
import { fakeCloud } from "./chief-brain-cc-fake.ts"
import { http, inDO, op, sessionToken, testEnv, useCcSettings } from "./chief-brain-cc-harness.ts"

/**
 * The computer of a Chief that runs on its owner's Mac (chief-brain-cc/local-computer.ts, chief-brain/local-computer-routes.ts):
 * the same Chief computer a Cloud Chief has (a sandbox, not a team Cloud machine), keyed by the session's user and the Mac's
 * id for the Chief. Freestyle is faked at its HTTP boundary (chief-brain-cc-fake.ts).
 */
useCcSettings()

const person = async (sub: string) => {
  const token = await sessionToken(sub)
  await op(token, "user.ensure", {})
  return token
}
const path = (chief: string, sub = "") => `/v1/local-chiefs/${chief}/computer${sub}`
const provision = (token: string, chief: string) => http("POST", path(chief, "/control"), token, { action: "provision" })
const status = async (token: string, chief: string) => (await http("GET", path(chief), token)).json.value
/** The status once `until` holds (the computer is made in the background). */
const settled = async (token: string, chief: string, until: (v: any) => boolean) => {
  let now = await status(token, chief)
  for (let i = 0; i < 200 && !until(now); i++) now = (await new Promise((r) => setTimeout(r, 25)), await status(token, chief))
  return now
}

describe("a local Chief's computer", { timeout: 120_000 }, () => {
  it("makes a new computer for each Chief, answers the same one again, and keeps it from other people", async () => {
    const cloud = fakeCloud(() => "ok")
    const token = await person("chief-local-computer")
    expect(await status(token, "conv_mario")).toMatchObject({ used: false, entitled: true, computer: null, control: { holder: "chief" } })
    const first = await provision(token, "conv_mario")
    expect(first.status, first.text).toBe(202)
    expect(first.json.value).toEqual({ provisioning: true })
    const mario = (await settled(token, "conv_mario", (v) => v.computer !== null)).computer
    expect(mario).toMatchObject({ state: "running" })
    // A sandbox of the Chief computer's size, never a team Cloud machine.
    expect(cloud.sizes.get(mario.id)).toMatchObject({ cpu: 4, memory: 8192 })
    // Asked again: the one it has, nothing more made.
    const made = cloud.made.length
    expect((await provision(token, "conv_mario")).json.value.computer.id).toBe(mario.id)
    expect(cloud.made.length).toBe(made)
    // Another Chief of the same person gets a new computer of its own.
    expect((await provision(token, "conv_luigi")).status).toBe(202)
    const luigi = (await settled(token, "conv_luigi", (v) => v.computer !== null)).computer
    expect(luigi.id).not.toBe(mario.id)
    expect(cloud.made.length).toBe(made + 1)
    // Someone else asking for the same Chief id reaches their own (none), never this one.
    const other = await person("chief-local-computer-other")
    expect(await status(other, "conv_mario")).toMatchObject({ computer: null })
    expect((await http("GET", path("conv_mario", "/screen"), other)).status).toBe(404)
    expect((await http("POST", path("conv_mario", "/control"), other, { action: "take_over" })).status).toBe(404)
    expect((await http("POST", path("conv_mario", "/act"), other, { op: "click", x: 1, y: 1 })).status).toBe(404)
  })

  it("refuses an owner without a Cloud plan and makes nothing", async () => {
    const cloud = fakeCloud(() => "ok")
    const token = await person("chief-local-computer-unpaid")
    const r = await provision(token, "conv_mario")
    expect(r.status, r.text).toBe(403)
    expect(r.json.error.code).toBe("cloud.plan.required")
    expect(await status(token, "conv_mario")).toMatchObject({ entitled: false, computer: null })
    expect(cloud.made.length).toBe(0)
  })

  it(`holds one owner to ${LOCAL_COMPUTER_CAP} local-Chief computers at a time, and frees a slot when one is gone`, async () => {
    const cloud = fakeCloud(() => "ok")
    const token = await person("chief-local-computer-cap")
    const chiefs = Array.from({ length: LOCAL_COMPUTER_CAP }, (_, i) => `chief-${i}`)
    for (const chief of chiefs) {
      expect((await provision(token, chief)).status).toBe(202)
      await settled(token, chief, (v) => v.computer !== null)
    }
    const over = await provision(token, "chief-over")
    expect(over.status, over.text).toBe(409)
    expect(over.json.error).toMatchObject({ code: "computer.local_limit", cap: LOCAL_COMPUTER_CAP })
    expect(cloud.made.length).toBe(LOCAL_COMPUTER_CAP)
    // A Chief that has one is not refused its own.
    expect((await provision(token, chiefs[0]!)).status).toBe(200)
    // One computer ends (its TTL, or deleted at Freestyle): once its reservation is old, its slot is free again.
    const gone = (await status(token, chiefs[0]!)).computer.id as string
    cloud.deleted.push(gone)
    const user = (await op(token, "user.ensure", {})).value.id as string
    const later = Date.now() + 11 * 60_000
    const registry = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`local:${user}/computers`))
    expect(await inDO(registry, (b) => reserveLocalComputer(b, user, "chief-over", LOCAL_COMPUTER_CAP, later))).toEqual({ ok: true })
    // And the next one over is refused again.
    expect(await inDO(registry, (b) => reserveLocalComputer(b, user, "chief-over-2", LOCAL_COMPUTER_CAP, later))).toMatchObject({ ok: false, held: LOCAL_COMPUTER_CAP })
  })

  it("lets the person take over and drive it, and refuses the Chief's own verbs while they hold it", async () => {
    fakeCloud(() => "ok")
    const token = await person("chief-local-computer-lease")
    expect((await http("POST", path("conv_mario", "/act"), token, { op: "screenshot" })).status).toBe(404)
    expect((await provision(token, "conv_mario")).status).toBe(202)
    await settled(token, "conv_mario", (v) => v.computer !== null)
    const act = (body: unknown) => http("POST", path("conv_mario", "/act"), token, body)
    const click = await act({ op: "click", x: 3, y: 4, shot: false })
    expect(click.status, click.text).toBe(200)
    expect(click.json.value).toMatchObject({ done: "click" })
    expect((await act({ op: "setup" })).status).toBe(400)
    expect((await http("POST", path("conv_mario", "/input"), token, { op: "click", x: 1, y: 1 })).json.error.code).toBe("computer.not_human")
    const took = await http("POST", path("conv_mario", "/control"), token, { action: "take_over" })
    expect(took.json.value.control).toMatchObject({ holder: "human", by: "human" })
    expect((await http("POST", path("conv_mario", "/input"), token, { op: "click", x: 1, y: 1 })).status).toBe(200)
    const held = await act({ op: "click", x: 5, y: 6 })
    expect(held.status).toBe(409)
    expect(held.json.error.code).toBe("computer.human_has_control")
    expect((await http("POST", path("conv_mario", "/control"), token, { action: "hand_back" })).json.value.control.holder).toBe("chief")
    expect((await act({ op: "move", x: 7, y: 8, shot: false })).status).toBe(200)
  })

  it("refuses provision where the Claude Code route is not configured, and makes nothing", async () => {
    const cloud = fakeCloud(() => "ok")
    const token = await person("chief-local-computer")
    const was = testEnv.CHIEF_CC_ENABLED
    testEnv.CHIEF_CC_ENABLED = "0"
    try {
      const r = await provision(token, "conv_off")
      expect(r.status, r.text).toBe(409)
      expect(r.json.error.code).toBe("computer.unavailable")
    } finally {
      testEnv.CHIEF_CC_ENABLED = was
    }
    expect(cloud.made.length).toBe(0)
  })

  it("deletes a Chief's computer for its owner, which frees its slot at once", async () => {
    const cloud = fakeCloud(() => "ok")
    const token = await person("chief-local-computer-delete")
    const chiefs = Array.from({ length: LOCAL_COMPUTER_CAP }, (_, i) => `del-${i}`)
    for (const chief of chiefs) {
      expect((await provision(token, chief)).status).toBe(202)
      await settled(token, chief, (v) => v.computer !== null)
    }
    expect((await provision(token, "del-over")).status).toBe(409)
    const gone = (await status(token, chiefs[0]!)).computer.id as string
    const del = await http("POST", path(chiefs[0]!, "/control"), token, { action: "delete" })
    expect(del.status, del.text).toBe(200)
    expect(cloud.deleted).toContain(gone)
    expect(await status(token, chiefs[0]!)).toMatchObject({ computer: null })
    // Someone else's delete reaches only their own (none).
    const other = await person("chief-local-computer-other")
    expect((await http("POST", path(chiefs[1]!, "/control"), other, { action: "delete" })).status).toBe(200)
    expect((await status(token, chiefs[1]!)).computer).not.toBeNull()
    // The freed slot is there now, not after the reservation's hold.
    expect((await provision(token, "del-over")).status).toBe(202)
  })

  it("gives the slot back when a provision is refused", async () => {
    fakeCloud(() => "ok")
    const token = await person("chief-local-computer-unpaid")
    for (const chief of ["a", "b", "c", "d"]) expect((await provision(token, `refused-${chief}`)).status).toBe(403)
    const user = (await op(token, "user.ensure", {})).value.id as string
    const registry = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`local:${user}/computers`))
    expect(await inDO(registry, (b) => reserveLocalComputer(b, user, "next", 1))).toEqual({ ok: true })
  })

  it("never names the provider when the computer does not answer", async () => {
    fakeCloud(() => "ok")
    const token = await person("chief-local-computer-lease")
    expect((await provision(token, "conv_quiet")).status).toBe(202)
    await settled(token, "conv_quiet", (v) => v.computer !== null)
    const spy = vi.mocked(globalThis.fetch)
    const inner = spy.getMockImplementation()!
    spy.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const req = new Request(input, init)
      if (/\/exec-await$/.test(new URL(req.url).pathname)) return new Response("down", { status: 503 })
      return inner(req)
    })
    try {
      const r = await http("POST", path("conv_quiet", "/act"), token, { op: "click", x: 1, y: 1, shot: false })
      expect(r.status).toBeGreaterThanOrEqual(500)
      expect(JSON.stringify(r.json)).not.toMatch(/freestyle/i)
    } finally {
      spy.mockImplementation(inner)
    }
  })
})
