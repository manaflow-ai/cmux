import { afterEach, describe, expect, it, vi } from "vitest"
import type { Env } from "../src/env.ts"
import { freestyleHands } from "../src/providers/freestyle/hand.ts"
import { FreestyleDriver } from "../src/providers/freestyle/team-vm.ts"

/** Every Freestyle VM create (POST /v5/vms) names the owning team or user as its customer (freestyle@0.2.21, #27667). */

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

const TEAM = `team_${"t".repeat(20)}`
const handEnv = { HAND_FREESTYLE_API_KEY: "test-only-key", HAND_SANDBOX_SNAPSHOT: "sh-hand", CLOUD_FREESTYLE_API_URL: "https://freestyle.test" } as unknown as Env

describe("Freestyle VM create customer", () => {
  it("tags a team VM with its team", async () => {
    stubFreestyle()
    await new FreestyleDriver("test-only-key", "https://freestyle.test", "sh-team").ensureVm("cmuxnp-test-tvm-a", TEAM, 1)
    expect(creates).toHaveLength(1)
    expect(creates[0]).toMatchObject({ slug: "cmuxnp-test-tvm-a", metadata: { cmux_team: TEAM, cmux_epoch: "1" }, customer: { customerId: TEAM } })
  })

  it("tags a hand sandbox with its owner", async () => {
    stubFreestyle()
    expect(await freestyleHands.create(handEnv, { name: "cmuxnp-test-hand-a", hand: "hand_a", owner: "user_owner-1", deployment: "https://api.test" })).toEqual({ id: "fsvm-1" })
    expect(creates[0]).toMatchObject({ metadata: { cmux_owner: "user_owner-1" }, customer: { customerId: "user_owner-1" } })
  })

  it("still makes the VM, untagged, when the owner id is not a valid customer id", async () => {
    stubFreestyle()
    expect(await freestyleHands.create(handEnv, { name: "cmuxnp-test-hand-b", hand: "hand_b", owner: "not a customer id", deployment: "https://api.test" })).toEqual({ id: "fsvm-1" })
    expect(creates[0]).not.toHaveProperty("customer")
  })
})
