import CmuxCloud
import CmuxSurfaceCatalogModel
import Testing

@Suite("Cloud Machines header count agrees with the listed machines")
struct CloudMachinesUsageReconcileTests {
    private func machine(_ id: String, usesResourcePool: Bool = true) -> MachineSnapshot {
        MachineSnapshot(
            id: id, provider: "freestyle", image: "", isDesktop: false,
            activity: usesResourcePool ? .ready : .attention("paused"),
            usesResourcePool: usesResourcePool
        )
    }

    @Test("a stale zero count rises to the one running machine the tree lists")
    func staleZeroRisesToListedMachine() {
        let stale = CloudMachinesUsage(activeCount: 0, maxActiveVms: 5, isPaidPlan: true)
        let listed = MachineSnapshotBuilder.activeCount(of: [machine("vm-1")])
        let usage = stale.reconciled(listedActiveCount: listed)
        #expect(usage.activeCount == 1)
        #expect(usage.maxActiveVms == 5)
    }

    @Test("paused rows do not raise the count")
    func pausedRowsDoNotCount() {
        let usage = CloudMachinesUsage(activeCount: 0, maxActiveVms: 5, isPaidPlan: true)
        let listed = MachineSnapshotBuilder.activeCount(of: [machine("vm-1", usesResourcePool: false)])
        #expect(usage.reconciled(listedActiveCount: listed).activeCount == 0)
    }

    @Test("a larger server count still wins over the listed rows")
    func serverCountWinsWhenLarger() {
        let usage = CloudMachinesUsage(activeCount: 3, maxActiveVms: 5, isPaidPlan: true)
        #expect(usage.reconciled(listedActiveCount: 1) == usage)
    }

    @Test("a catalog-only machine counts once its status holds a slot")
    func catalogOnlyMachineCounts() {
        let catalog = SurfaceCatalogSnapshot(
            machines: [SurfaceMachineInfo(id: .cloud("vm-2"), name: "vm-2", status: "running", hasDesktop: false, linkState: .connected)],
            resources: [],
            projections: []
        )
        let listed = MachineSnapshotBuilder.includingCatalogMachines([], catalog: catalog)
        let usage = CloudMachinesUsage(activeCount: 0, maxActiveVms: 5, isPaidPlan: false)
        #expect(usage.reconciled(listedActiveCount: MachineSnapshotBuilder.activeCount(of: listed)).activeCount == 1)
    }
}
