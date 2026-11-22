import { afterEach, describe, expect, it, vi } from "vitest"
import type { Env } from "../src/env.ts"
import { freestyleHands } from "../src/providers/freestyle/hand.ts"
import { freestyleTeamVm } from "../src/providers/freestyle/team-vm.ts"

/**
 * Leo, 2026-10-30: "we're saying no auto pausing of the freestyle vms for now". Every Freestyle VM create
 * asks for idleTimeoutSeconds -1 (never pause for idleness) unless the Worker var CLOUD_IDLE_PAUSE is "on"
 * (auto-pause.ts); the CloudDO side is in cloud-idle-backstop.test.ts.
 */

const creates: Array<Record<string, unknown>> = []
const stubFreestyle = () =>
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const req = new Request(input, init)
    if (req.method === "POST" && new URL(req.url).pathname === "/v5/vms") {
      creates.push((await req.json()) as Record<string, unknown>)
      return Response.json({ id: `fsvm-${creates.length}`, state: "starting" })
    }
    return Response.json({ code: "UNMOCKED" }, { status: 500 })
  })
afterEach(() => {
  creates.length = 0
  vi.restoreAllMocks()
})

const TEAM = `team_${"n".repeat(20)}`
const base = { FREESTYLE_API_KEY: "test-only-key", FREESTYLE_API_URL: "https://freestyle.test", HAND_FREESTYLE_API_KEY: "test-only-key", HAND_SANDBOX_SNAPSHOT: "sh-hand", CLOUD_FREESTYLE_API_URL: "https://freestyle.test" }
const hand = { name: "cmuxnp-test-hand-n", hand: "hand_n", owner: "user_owner-n", deployment: "https://api.test" }

describe("Freestyle creates never pause for idleness by default", () => {
  it("a team VM and a hand sandbox are created with idleTimeoutSeconds -1 when CLOUD_IDLE_PAUSE is unset", async () => {
    stubFreestyle()
    const env = base as unknown as Env
    await freestyleTeamVm.make(env, "sh-team").ensureVm("cmuxnp-test-tvm-n", TEAM, 1)
    await freestyleHands.create(env, hand)
    expect(creates.map((c) => c.idleTimeoutSeconds)).toEqual([-1, -1])
  })

  it("CLOUD_IDLE_PAUSE \"on\" brings the old timers back: 600 s for a team VM, 1800 s for a hand sandbox", async () => {
    stubFreestyle()
    const env = { ...base, CLOUD_IDLE_PAUSE: "on" } as unknown as Env
    await freestyleTeamVm.make(env, "sh-team").ensureVm("cmuxnp-test-tvm-n", TEAM, 1)
    await freestyleHands.create(env, hand)
    expect(creates.map((c) => c.idleTimeoutSeconds)).toEqual([600, 1800])
  })
})
