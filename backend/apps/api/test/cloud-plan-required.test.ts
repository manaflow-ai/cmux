import { CLOUD_PLAN_CATALOG, cloudEntryPlan } from "@cmux/protocol"
import { describe, expect, it } from "vitest"
import vectors from "../../../catalog/cloud-vectors.json"
import { fireAlarm } from "./setup/alarm.ts"
import { ALLOWED_USERS, cloudTestUser } from "./setup/cloud-teams.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { cloudStub, frame, reply, SIZE } from "./cloud-bind-support.ts"

/**
 * CLOUD-PLAN-REQUIRED-DETAILS (coordinator, 2026-10-04): cloud.plan.required carries details.plan,
 * the catalog plan that lifts it, so the app can show "See plans". Both refusal sites: the create
 * reducer and the provider-call path (the allowlist changed between the intent and the call).
 */

// Allowed users 190..199 (other cloud files use lower ranges); refused users far above ALLOWED_USERS.
let seq = 190
const who = (allowed: boolean) => {
  const user = allowed ? cloudTestUser(++seq) : cloudTestUser(ALLOWED_USERS + 400 + ++seq)
  const team = personalTeamIdFor(user)
  return { team, p: { identity: `user:${user}`, user, team, kind: "session" as const }, stub: cloudStub(team) }
}

describe("cloud.plan.required names the plan that lifts it", { timeout: 60_000 }, () => {
  it("the entry plan comes from the plan catalog, and the shared vector carries it", () => {
    const plan = cloudEntryPlan()
    expect(CLOUD_PLAN_CATALOG.some((p) => p.id === plan && p.cloud)).toBe(true)
    const v = (vectors as unknown as { cases: Array<{ name: string; responses: Array<{ body: any }> }> }).cases.find((c) => c.name === "machine.create.plan_required")!
    expect(v.responses[0]!.body.error).toMatchObject({ code: "cloud.plan.required", details: { plan } })
  })

  it("the create reducer refusal carries details.plan", async () => {
    const x = who(false)
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))).toMatchObject({ t: "reject", code: "cloud.plan.required", details: { plan: cloudEntryPlan() } })
  })

  it("the provider-call refusal (allowlist removed after the intent) carries details.plan on the same-key retry", async () => {
    const x = who(true)
    await x.stub.fakeControl({ fail_next: 1 } as never)
    const f = frame("cloud.machine.create", { size: SIZE })
    expect(reply(await x.stub.submit(x.team, x.p, f))).toMatchObject({ t: "reject", code: "mutation.indeterminate" })
    await x.stub.fakeControl({ unset: ["CLOUD_ALLOWED_TEAMS"], advance_ms: 10 * 60_000 } as never)
    await fireAlarm(x.stub)
    expect(reply(await x.stub.submit(x.team, x.p, f))).toMatchObject({ t: "reject", code: "cloud.plan.required", details: { plan: cloudEntryPlan() } })
  })
})
