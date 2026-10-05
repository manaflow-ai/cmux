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
    var includeLocalMachine = CloudTreeNodeBuilder.includesLocalMachine
    var source: CloudTreeMachineSource = .cloud
    var devicesSection: CloudTreeDevicesSection = .init()
    var showsCloudVPNWarning = false
    var canCreateCloudMachine = false
    var cloudMachinesUsage: CloudMachinesUsage? = nil
    var cloudMachinesRefresh: CloudTreeSectionRefresh? = nil
    var localeIdentifier: String = Locale.current.identifier

    func nodes(now: Date = .now, resourceNodeBuilder: CloudTreeMachineResourceNodeBuilder = .init()) -> [CloudTreeNode] {
        CloudTreeNodeBuilder.nodes(
            machines: machines,
            pendingCreates: pendingCreates, adoptedOperationIDs: adoptedOperationIDs,
            snapshot: snapshot, localWorkspaces: localWorkspaces,
            unreadTerminalIDs: unreadTerminalIDs,
            pinnedMachineIDs: pinnedMachineIDs.union(machines.filter(\.isPinned).map(\.id)),
            includeLocalMachine: includeLocalMachine,
            source: source, devicesSection: devicesSection,
            showsCloudVPNWarning: showsCloudVPNWarning,
            canCreateCloudMachine: canCreateCloudMachine,
            cloudMachinesUsage: cloudMachinesUsage,
            cloudMachinesRefresh: cloudMachinesRefresh,
            now: now, resourceNodeBuilder: resourceNodeBuilder
        )
    }
}
