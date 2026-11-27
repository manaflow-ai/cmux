@testable import CmuxCloud
import Foundation
import Testing

/// Running, provisioning, and paused machines all occupy a plan slot.
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
    func headerCountsPausedMachinesAgainstThePlan() throws {
        let snapshots = Self.fleet.map { MachineSnapshotBuilder.snapshot(from: $0) }
        #expect(MachineSnapshotBuilder.activeCount(of: snapshots) == 4)
        let limits = VMPlanLimits(maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 0)
        let plan = try #require(MachineSnapshotBuilder.planSnapshot(
            activeCount: MachineSnapshotBuilder.activeCount(of: snapshots),
            limits: limits
        ))
        #expect(plan.usage.compactCount == "4/5")
    }

    @Test
    func listPageCountMatchesTheServerCount() {
        let page = VMListPage(vms: Self.fleet, limits: VMPlanLimits(maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 0))
        #expect(page.activeMachineCount == 4)
        let reported = VMListPage(
            vms: Self.fleet,
            limits: VMPlanLimits(maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 0, activeVmCount: 3)
        )
        #expect(reported.activeMachineCount == 3)
    }
    @Test
    func pausedPlusMachineKeepsItsOnlySlot() throws {
        let page = VMListPage(vms: [Self.summary("saved", "paused")], limits: VMPlanLimits(
            maxActiveVms: 1, planId: "go", freeAccessWindowDays: 0
        ))
        let plan = try #require(MachineSnapshotBuilder.planSnapshot(activeCount: page.activeMachineCount, limits: page.limits))
        #expect(plan.usage.compactCount == "1/1")
        #expect(plan.isAtLimit)
        #expect(VMListPage(vms: [], limits: page.limits).activeMachineCount == 0)
    }

}
