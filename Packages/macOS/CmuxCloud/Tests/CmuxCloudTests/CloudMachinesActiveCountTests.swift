@testable import CmuxCloud
import Foundation
import Testing

/// The header's "N/5" must be the count the server's active-VM limit uses:
/// running and provisioning machines. Paused machines are listed but do not
/// hold a slot, so counting every listed row says "full" when it is not.
@Suite
struct CloudMachinesActiveCountTests {
    private static func summary(_ id: String, _ status: String) -> VMSummary {
        VMSummary(id: id, provider: "freestyle", status: status, image: "snapshot", createdAt: 0)
    }

    private static let fleet = [
        summary("running-a", "running"),
        summary("provisioning-b", "provisioning"),
        summary("paused-c", "paused"),
        summary("paused-d", "paused"),
    ]

    @Test
    func headerCountsOnlyMachinesHoldingAnActiveSlot() throws {
        let snapshots = Self.fleet.map { MachineSnapshotBuilder.snapshot(from: $0) }
        #expect(MachineSnapshotBuilder.activeCount(of: snapshots) == 2)
        let limits = VMPlanLimits(maxActiveVms: 2, planId: "pro", freeAccessWindowDays: 0)
        let plan = try #require(MachineSnapshotBuilder.planSnapshot(
            activeCount: MachineSnapshotBuilder.activeCount(of: snapshots),
            limits: limits
        ))
        #expect(plan.usage.compactCount == "2/2")
    }

    @Test
    func listPageCountMatchesTheServerCount() {
        let page = VMListPage(vms: Self.fleet, limits: VMPlanLimits(maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 0))
        #expect(page.activeMachineCount == 2)
        let reported = VMListPage(
            vms: Self.fleet,
            limits: VMPlanLimits(maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 0, activeVmCount: 3)
        )
        #expect(reported.activeMachineCount == 3)
    }
}
