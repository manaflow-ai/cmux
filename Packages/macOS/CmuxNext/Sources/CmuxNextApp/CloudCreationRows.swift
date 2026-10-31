import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCloud
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
                // A paused machine waits for an attach: no spinner.
                progress: stage.isPaused ? nil : SidebarProgress(value: stage.failure == nil ? (stage == .ready ? 1 : nil) : 1, isError: stage.failure != nil),
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
    static func machine(_ session: CloudMachineSession, compatibility: DaemonCompatibility?, limits: CloudMachineLimits? = nil,
                        updates: DaemonUpdateBoard) -> SidebarMachine {
        var header = SidebarBridge.machine(for: session.daemon, name: session.machine.title, kind: .cloud, live: session.machine.status.isLive,
                             compatibility: compatibility)
        header.cost = cost(session.machine, limits: limits)
        let stage = session.stage
        if let changing = changeStatus(stage) {
            // A pause, resume or delete on its way reads as itself, whatever the link says.
            header.status = changing
        } else if case .paused(let idle) = stage, header.status == .connecting || header.status == .offline {
            // Paused never reads failed: "Paused (idle)" or "Paused"; an attach resumes it.
            header.status = idle ? .pausedIdle : .paused
        } else if let failure = stage.failure, header.status == .connecting || header.status == .offline {
            header.status = session.stageInput.isDisconnect ? .disconnected : .failed
            header.detail = failure
        }
        // The server answered a pause, resume or resize at once and its provider call failed
        // after: the machine went back, and the header's tooltip says why.
        if let failure = session.machine.lastChangeFailure, header.detail != failure.text {
            header.detail = [header.detail, CloudStrings.changeFailed(failure.text)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        header.detail = withUpdate(header.detail, updates.targets[CloudMachineUpdateTarget.id(session.machineID)],
                                   compatibility: compatibility)
        return header.redialing(session.link?.redial.isRedialing == true)
    }

    /// The header status of a change the server accepted (``CloudMachineStage/isChanging``).
    static func changeStatus(_ stage: CloudMachineStage) -> SidebarMachine.Status? {
        switch stage {
        case .pausing: .pausing
        case .resuming: .resuming
        case .deleting: .deleting
        default: nil
        }
    }

    /// The automatic update's state (``CloudMachineUpdates``) in a machine header's detail: while it
    /// runs or retries it replaces "Update it to turn on every feature"; a result follows the rest.
    /// A failure goes once the machine runs the build the update was to (Update Machine fixed it),
    /// not merely one that serves every capability: an older build can, and is still not the app's.
    static func withUpdate(_ detail: String?, _ event: DaemonUpdateEvent?, compatibility: DaemonCompatibility?) -> String? {
        guard let event else { return detail }
        let line = DaemonUpdateBoard.line(event.state)
        switch event.state {
        // "Update it to turn on every feature" would ask for what cannot happen: what still works instead.
        case .updating, .retrying, .offline, .cannotUpdate: return line
        case .failed where event.build.map { build in DaemonBuildCommit(compatibility?.buildCommit)?.sameCommit(build) == true } == true:
            return detail
        case .updated, .failed: return [detail, line].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        case .cleared: return detail
        }
    }

    /// A Cloud machine's cost line from server facts: its rate, when it last
    /// started (nil unless it is live, so a paused machine shows no running
    /// cost) and the account's cap. Nil when the server sent none of them.
    static func cost(_ machine: CloudMachine, limits: CloudMachineLimits?) -> SidebarMachine.Cost? {
        let since = machine.status.isLive ? machine.runningSince : nil
        let cap = limits.map { SidebarMachine.Cost.Cap(maxActiveVms: $0.maxActiveVms, running: $0.activeVmCount) }
        guard machine.hourlyRateUsd != nil || since != nil || cap != nil else { return nil }
        return SidebarMachine.Cost(hourlyRateUsd: machine.hourlyRateUsd, runningSince: since, cap: cap)
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
