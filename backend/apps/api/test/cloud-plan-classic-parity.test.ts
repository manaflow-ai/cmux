import { describe, expect, it } from "vitest"
import { PAID_PLAN_LIMITS, paidPlanLimits } from "../src/domains/cloud-plan.ts"

/**
 * cmux-next sells the same Stripe products as classic cmux (plans/cmux-next/paid-product-DESIGN.md
 * section 1), so a plan must grant the same Cloud machines in both apps. These numbers are classic's
 * live allowance on main (web/services/vms/entitlements.ts, machineSpec.ts; PR #26732 cmux Plus):
 * - Plus ($15, plan id `go`): one machine, Pro sizes (4, 8, 16 GiB; 8 vCPU), disk up to 128 GiB,
 *   no monthly hour cap.
 * - Pro, Founders, Team: five machines, up to 8 vCPU / 16 GiB, disk 128 GiB.
 * - Max: five machines, up to 32 vCPU / 64 GiB, disk 256 GiB.
 */
const GiB = 1024

describe("Cloud plan limits match classic cmux", () => {
  it("Plus (go) is one machine with Pro sizes and no hour cap", () => {
    expect(paidPlanLimits("go")).toMatchObject({
      plan_id: "go",
      max_active: 1,
      memory_options_mb: [4 * GiB, 8 * GiB, 16 * GiB],
      vm_hours_included: null,
      max_cpu: 8,
      max_disk_mb: 128 * GiB,
      upgrade_plan: "pro"
    })
  })

  it.each(["pro", "founders", "team"])("%s is five machines up to 8 vCPU / 16 GiB and 128 GiB disk", (plan) => {
    expect(paidPlanLimits(plan)).toMatchObject({ max_active: 5, memory_options_mb: [4 * GiB, 8 * GiB, 16 * GiB], vm_hours_included: null, max_cpu: 8, max_disk_mb: 128 * GiB })
  })

  it("Max is five machines up to 32 vCPU / 64 GiB and 256 GiB disk", () => {
    expect(paidPlanLimits("max")).toMatchObject({ max_active: 5, max_cpu: 32, max_disk_mb: 256 * GiB, vm_hours_included: null, upgrade_plan: null })
    expect(PAID_PLAN_LIMITS.max!.memory_options_mb).toEqual([4 * GiB, 8 * GiB, 16 * GiB, 32 * GiB, 64 * GiB])
  })
})
