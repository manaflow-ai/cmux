// A deployment with no CLOUD_DO binding (the local env) answers Cloud calls with a retryable outage, never a TypeError.
import { describe, expect, it } from "vitest"
import { CLOUD_UNBOUND, platformCloud } from "../src/platform-cloud.ts"

describe("platformCloud without a CLOUD_DO binding", () => {
  it("rejects every RPC with CLOUD_UNBOUND", async () => {
    const cloud = platformCloud(undefined, "team_a")
    await expect(cloud.readOp("team_a", { identity: "u", kind: "session", user: "u", team: "team_a" } as never, "cloud.machine.list", {})).rejects.toThrow(CLOUD_UNBOUND)
    await expect(cloud.automationExec("team_a", null, "vm_1", "true", null, 1000)).rejects.toThrow(CLOUD_UNBOUND)
  })
})
