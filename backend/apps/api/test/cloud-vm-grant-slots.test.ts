import { describe, expect, it } from "vitest"
import { grantRank, higherGrant } from "../src/cloud-vm-plan.ts"
import { readCloudVmGrant, stackServer } from "../src/stack-server.ts"

/**
 * One sign-in record may hold a classic operator grant (`cmuxVmPlan`) and a cmux NEXT operator grant
 * (`cmuxNextVmPlan`) at once. The grant read answers the effective one for cmux NEXT Cloud, in the same `vm_plan`.
 */

const grant = (meta: Record<string, unknown>) => readCloudVmGrant(meta)

describe("readCloudVmGrant: the effective grant of a record with two grant slots", () => {
  it("no NEXT grant: the classic value unchanged, restrictions and a legacy NEXT id included", () => {
    expect(grant({})).toBeNull()
    expect(grant({ cmuxVmPlan: "pro" })).toBe("pro")
    expect(grant({ cmuxVmPlan: "free" })).toBe("free")
    expect(grant({ cmuxVmPlan: "" })).toBe("")
    expect(grant({ cmuxVmPlan: 7 })).toBe("")
    expect(grant({ cmuxVmPlan: null })).toBeNull()
    expect(grant({ cmuxVmPlan: "next_pro" })).toBe("next_pro")
    expect(grant({ cmuxVmPlan: "next_max" })).toBe("next_max")
  })

  it("no classic value: the NEXT grant, trimmed and lowercased", () => {
    expect(grant({ cmuxNextVmPlan: "next_pro" })).toBe("next_pro")
    expect(grant({ cmuxNextVmPlan: " NEXT_MAX " })).toBe("next_max")
    expect(grant({ cmuxVmPlan: null, cmuxNextVmPlan: "next_max" })).toBe("next_max")
  })

  it("both set: the higher by rank, the NEXT grant at an equal rank", () => {
    expect(grant({ cmuxVmPlan: "pro", cmuxNextVmPlan: "next_max" })).toBe("next_max")
    expect(grant({ cmuxVmPlan: "max", cmuxNextVmPlan: "next_pro" })).toBe("max")
    expect(grant({ cmuxVmPlan: "pro", cmuxNextVmPlan: "next_pro" })).toBe("next_pro")
    expect(grant({ cmuxVmPlan: "founders", cmuxNextVmPlan: "next_pro" })).toBe("next_pro")
    expect(grant({ cmuxVmPlan: "max", cmuxNextVmPlan: "next_max" })).toBe("next_max")
    expect(grant({ cmuxVmPlan: "go", cmuxNextVmPlan: "next_pro" })).toBe("next_pro")
    // A legacy NEXT id in the classic slot beside a new NEXT grant: the higher.
    expect(grant({ cmuxVmPlan: "next_max", cmuxNextVmPlan: "next_pro" })).toBe("next_max")
    expect(grant({ cmuxVmPlan: "next_pro", cmuxNextVmPlan: "next_max" })).toBe("next_max")
  })

  it("cmux NEXT Plus ranks with Plus (go), below Pro: it never hides a higher grant", () => {
    expect(grant({ cmuxNextVmPlan: "next_plus" })).toBe("next_plus")
    expect(grant({ cmuxVmPlan: "next_plus" })).toBe("next_plus")
    expect(grant({ cmuxVmPlan: "go", cmuxNextVmPlan: "next_plus" })).toBe("next_plus")
    expect(grant({ cmuxVmPlan: "pro", cmuxNextVmPlan: "next_plus" })).toBe("pro")
    expect(grant({ cmuxVmPlan: "max", cmuxNextVmPlan: "next_plus" })).toBe("max")
    expect(grant({ cmuxVmPlan: "next_pro", cmuxNextVmPlan: "next_plus" })).toBe("next_pro")
    expect(grant({ cmuxVmPlan: "free", cmuxNextVmPlan: "next_plus" })).toBe("next_plus")
  })

  it("a classic restriction never hides a NEXT grant", () => {
    expect(grant({ cmuxVmPlan: "free", cmuxNextVmPlan: "next_pro" })).toBe("next_pro")
    expect(grant({ cmuxVmPlan: "", cmuxNextVmPlan: "next_max" })).toBe("next_max")
    expect(grant({ cmuxVmPlan: 7, cmuxNextVmPlan: "next_pro" })).toBe("next_pro")
  })

  it("a cmuxNextVmPlan that is not exactly a NEXT id changes nothing", () => {
    for (const junk of ["pro", "max", "free", "", "next", "next_ultra", "next_pro_x", 3, true, null, { plan: "next_pro" }, ["next_pro"]]) {
      expect(grant({ cmuxNextVmPlan: junk })).toBeNull()
      expect(grant({ cmuxVmPlan: "pro", cmuxNextVmPlan: junk })).toBe("pro")
      expect(grant({ cmuxVmPlan: "free", cmuxNextVmPlan: junk })).toBe("free")
      expect(grant({ cmuxVmPlan: "next_pro", cmuxNextVmPlan: junk })).toBe("next_pro")
    }
  })

  it("metadata that is not an object is no grant", () => {
    for (const m of [null, undefined, "next_pro", 1, ["next_pro"]]) expect(readCloudVmGrant(m)).toBeNull()
  })
})

describe("the sign-in service reads answer the combined grant, wire shape unchanged", () => {
  const env = { STACK_SECRET_SERVER_KEY: "sk", STACK_PROJECT_ID: "p" } as never
  const answering = (body: Record<string, unknown>) => async () => Response.json(body)

  it("a user's record", async () => {
    const s = stackServer(env, answering({ client_read_only_metadata: { cmuxVmPlan: "pro", cmuxNextVmPlan: "next_max" } }))!
    expect(await s.getUserVmPlan("u")).toEqual({ vm_plan: "next_max" })
    const legacy = stackServer(env, answering({ client_read_only_metadata: { cmuxVmPlan: "next_pro" } }))!
    expect(await legacy.getUserVmPlan("u")).toEqual({ vm_plan: "next_pro" })
    const restricted = stackServer(env, answering({ client_read_only_metadata: { cmuxVmPlan: "free", cmuxNextVmPlan: "next_pro" } }))!
    expect(await restricted.getUserVmPlan("u")).toEqual({ vm_plan: "next_pro" })
  })

  it("a shared team's record", async () => {
    const s = stackServer(env, answering({ display_name: "Acme", client_read_only_metadata: { cmuxVmPlan: "max", cmuxNextVmPlan: "next_pro" } }))!
    expect((await s.getTeam("t"))?.vm_plan).toBe("max")
    const next = stackServer(env, answering({ display_name: "Acme", client_read_only_metadata: { cmuxNextVmPlan: "next_max" } }))!
    expect((await next.getTeam("t"))?.vm_plan).toBe("next_max")
    const junk = stackServer(env, answering({ display_name: "Acme", client_read_only_metadata: { cmuxVmPlan: "pro", cmuxNextVmPlan: "garbage" } }))!
    expect((await junk.getTeam("t"))?.vm_plan).toBe("pro")
  })
})

describe("NEXT grants have a rank in the carried-grant comparison", () => {
  it("ranks next_pro with Pro and next_max with Max", () => {
    expect(grantRank("next_pro")).toBe(grantRank("pro"))
    expect(grantRank("next_max")).toBe(grantRank("max"))
    expect(grantRank("NEXT_MAX")).toBe(3)
  })

  it("a carried NEXT grant raises a lower own grant, and an own NEXT grant is no longer a restriction", () => {
    expect(higherGrant("go", null, "next_max")).toBe("next_max")
    expect(higherGrant(null, "pro", "next_max")).toBe("next_max")
    expect(higherGrant("next_pro", null, "max")).toBe("max")
    expect(higherGrant("next_max", null, "max")).toBe("next_max")
    // A real restriction still wins.
    expect(higherGrant("free", null, "next_max")).toBe("free")
  })
})
