import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// Cloud creations in the sidebar (cx-lu8f): a New Cloud Workspace has a row
/// from the click, before its machine or workspace exists, and a Cloud
/// machine's header says why it cannot connect. Its own type, so the
/// sidebar bridge does not grow.
enum CloudCreationRows {
    /// `sections` with one row per creation: in its machine's section once
    /// the machine exists, else in a section of its own. The row is
    /// selectable (its window shows the progress), never a placeholder, and
    /// shows the stage and a progress bar; it leaves once its workspace's
    /// own row is listed.
    static func adding(_ creations: [CloudMachineCreation], to sections: [SidebarRowSection]) -> [SidebarRowSection] {
        guard !creations.isEmpty else { return sections }
        var sections = sections
        let listed = Set(sections.flatMap(\.workspaces).map(\.id.rawValue))
        for creation in creations {
            if let opened = creation.workspaceID, listed.contains(opened) { continue }
            let stage = creation.stage
            let machineID = MachineID(creation.session?.machineID ?? creation.rowID)
            let row = SidebarWorkspace(
                id: WorkspaceID(creation.rowID), machineID: machineID,
                title: CloudStrings.newCloudWorkspaceTitle,
                status: CloudStrings.stage(stage), kind: .terminal,
                progress: SidebarProgress(value: stage.failure == nil ? (stage == .ready ? 1 : nil) : 1, isError: stage.failure != nil),
                isClosable: false, stage: CloudStrings.stage(stage))
            if let index = sections.firstIndex(where: { $0.machine?.id == machineID }) {
                sections[index].nodes.append(.workspace(row))
            } else {
                let machine = SidebarMachine(id: machineID, name: creation.machineTitle ?? CloudStrings.newMachine, kind: .cloud,
                                             status: stage.failure == nil ? .connecting : .failed, detail: stage.failure)
                sections.append(SidebarSection(kind: .machine(machine), nodes: [.workspace(row)]))
            }
        }
        return sections
    }

    /// A Cloud machine's header: its daemon's link state, and a failure
    /// (link or daemon gave up, the provider failed it) with its reason as
    /// the tooltip, so it keeps its header in the one list instead of
    /// "connecting" for ever.
    static func machine(_ session: CloudMachineSession, compatibility: DaemonCompatibility?) -> SidebarMachine {
        var header = SidebarBridge.machine(for: session.daemon, name: session.machine.title, kind: .cloud, live: session.machine.status.isLive,
                             compatibility: compatibility)
        if let failure = session.stage.failure, header.status == .connecting || header.status == .offline {
            header.status = .failed
            header.detail = failure
        }
        return header
    }

    /// A Cloud creation's row (cx-lu8f): no workspace yet, so no daemon command and no context menu.
    static func isRow(_ id: WorkspaceID, _ services: AppServices) -> Bool {
        services.cloud.creations.creation(row: id.rawValue) != nil
    }

    /// Selecting a creation's row shows its progress in this window; other
    /// gestures on it (close, drag, rename) do nothing. False for intents
    /// that do not touch a creation's row.
    static func handle(_ intent: SidebarIntent, bridge: SidebarBridge, state: WindowState) -> Bool {
        let services = bridge.services
        let creations = services.cloud.creations
        func isCreation(_ id: WorkspaceID) -> Bool { creations.creation(row: id.rawValue) != nil }
        switch intent {
        case .select(let id) where isCreation(id):
            bridge.model.apply(intent)
            return SidebarNavigation.showCreation(row: id.rawValue, in: state, services)
        case .close(let ids) where ids.contains(where: isCreation),
             .reorder(let ids, _) where ids.contains(where: isCreation),
             .move(let ids, _) where ids.contains(where: isCreation):
            bridge.resync()
            return true
        case .rename(let id, _) where isCreation(id):
            bridge.resync()
            return true
        default:
            return false
        }
    }
}
