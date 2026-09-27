import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// Value inputs to the outline, separate from its changing action closures.
struct CloudTreeBuildInputs: Equatable {
    var machines: [MachineSnapshot]
    var pendingCreates: [MachineCreateOperation] = []
    var adoptedOperationIDs: [String: UUID] = [:]
    var snapshot: SurfaceCatalogSnapshot
    var localWorkspaces: [CloudTreeLocalWorkspace] = []
    var unreadTerminalIDs: [String: Set<String>] = [:]
    var pinnedMachineIDs: Set<String> = []
    var source: CloudTreeMachineSource = .cloud
    var devicesSection: CloudTreeDevicesSection = .init()

    func nodes() -> [CloudTreeNode] {
        CloudTreeNodeBuilder.nodes(
            machines: machines,
            pendingCreates: pendingCreates, adoptedOperationIDs: adoptedOperationIDs,
            snapshot: snapshot, localWorkspaces: localWorkspaces,
            unreadTerminalIDs: unreadTerminalIDs,
            pinnedMachineIDs: pinnedMachineIDs.union(machines.filter(\.isPinned).map(\.id)),
            source: source, devicesSection: devicesSection
        )
    }
}
