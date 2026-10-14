import Foundation
import Testing
@testable import CmuxSurfaceCatalogModel

@Suite("Surface catalog device visibility")
struct SurfaceCatalogDeviceVisibilityTests {
    private let vm = SurfaceMachineID.cloud("vm-desktop")

    @Test("the sidebar filter keeps per-machine catalog state for visible machines")
    func visibilityKeepsMachineState() {
        let membership = CloudVMDisplayMembership(
            machine: vm,
            workspaceID: "ws-1",
            displayID: "display:1",
            clientID: "client",
            viewID: "view"
        )
        let snapshot = SurfaceCatalogSnapshot(
            machines: [SurfaceMachineInfo(id: vm, name: "Desktop", status: "running", hasDesktop: true, linkState: .connected)],
            resources: [],
            projections: [],
            staleMachineIDs: [vm],
            displayCreationMachines: [vm],
            pendingDisplayCreations: [vm],
            cloudDisplayMemberships: [membership]
        )

        let visible = snapshot.applyingDeviceVisibility(includesCloud: true, includesDevices: true, hiddenMacIDs: [])

        // The sidebar's New Display row reads this set. Dropping it made every
        // desktop VM report "Additional displays are unavailable".
        #expect(visible.displayCreationMachines == [vm])
        // The optimistic "Starting display…" row reads this set.
        #expect(visible.pendingDisplayCreations == [vm])
        #expect(visible.staleMachineIDs == [vm])
        #expect(visible.cloudDisplayMemberships == [membership])
    }

    @Test("hidden machines do not leak display creation state")
    func hiddenMachinesAreFiltered() {
        let snapshot = SurfaceCatalogSnapshot(
            machines: [SurfaceMachineInfo(id: vm, name: "Desktop", status: "running", hasDesktop: true, linkState: .connected)],
            resources: [],
            projections: [],
            displayCreationMachines: [vm]
        )

        let visible = snapshot.applyingDeviceVisibility(includesCloud: false, includesDevices: true, hiddenMacIDs: [])

        #expect(visible.machines.isEmpty)
        #expect(visible.displayCreationMachines == nil)
    }
}
