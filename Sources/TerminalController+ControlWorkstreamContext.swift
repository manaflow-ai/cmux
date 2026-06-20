import CmuxControlSocket
import CmuxWorkspaces
import Foundation

/// The workstream-domain witnesses for the ``ControlCommandCoordinator``.
/// TabManager resolution goes through the shared `resolveTabManager(routing:)`;
/// app structs are converted to the package's Sendable snapshots. Mutations
/// route through `WorkstreamCoordinator` (via TabManager's forwarding wrappers),
/// so the socket path shares the exact model logic the sidebar uses.
extension TerminalController: ControlWorkstreamContext {
    private func controlWorkstreamSnapshot(
        _ workstream: Workstream,
        tabManager: TabManager
    ) -> ControlWorkstreamSnapshot {
        ControlWorkstreamSnapshot(
            id: workstream.id,
            name: workstream.name,
            customColor: workstream.customColor,
            iconSymbol: workstream.iconSymbol,
            memberWorkspaceIDs: tabManager.workspaces.memberWorkspaceIds(ofWorkstream: workstream.id)
        )
    }

    func controlWorkstreamList(
        routing: ControlRoutingSelectors
    ) -> ControlWorkstreamListResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let workstreams = tabManager.workstreams.map {
            controlWorkstreamSnapshot($0, tabManager: tabManager)
        }
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(
            windowID: windowId,
            workstreams: workstreams,
            drilledInWorkstreamID: tabManager.drilledInWorkstreamId
        )
    }

    func controlCreateWorkstream(
        routing: ControlRoutingSelectors,
        name: String,
        workspaceIDs: [UUID],
        workspacesExplicit: Bool
    ) -> ControlWorkstreamCreateResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        // Validate any explicitly-listed members exist in the target window.
        let knownIds = Set(tabManager.tabs.map(\.id))
        let missing = workspaceIDs.filter { !knownIds.contains($0) }.map(\.uuidString)
        if !missing.isEmpty {
            return .workspaceNotFound(missing)
        }
        let id = tabManager.createWorkstream(name: name, memberWorkspaceIds: workspaceIDs)
        guard let workstream = tabManager.workstreams.first(where: { $0.id == id }) else {
            // Should not happen, but surface a deterministic shape if it does.
            return .workspaceNotFound([])
        }
        return .created(controlWorkstreamSnapshot(workstream, tabManager: tabManager))
    }

    func controlRenameWorkstream(
        routing: ControlRoutingSelectors,
        workstreamID: UUID,
        name: String
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard tabManager.workstreams.contains(where: { $0.id == workstreamID }) else { return false }
        tabManager.renameWorkstream(id: workstreamID, name: name)
        return true
    }

    func controlDeleteWorkstream(
        routing: ControlRoutingSelectors,
        workstreamID: UUID
    ) -> Int? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard tabManager.workstreams.contains(where: { $0.id == workstreamID }) else { return -1 }
        return tabManager.deleteWorkstream(id: workstreamID)
    }

    func controlAddWorkspaceToWorkstream(
        routing: ControlRoutingSelectors,
        workstreamID: UUID,
        workspaceID: UUID
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard tabManager.workstreams.contains(where: { $0.id == workstreamID }),
              tabManager.tabs.contains(where: { $0.id == workspaceID }) else { return false }
        tabManager.addWorkspaceToWorkstream(workspaceId: workspaceID, workstreamId: workstreamID)
        return true
    }

    func controlRemoveWorkspaceFromWorkstream(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard let tab = tabManager.tabs.first(where: { $0.id == workspaceID }),
              tab.workstreamId != nil else { return false }
        tabManager.removeWorkspaceFromWorkstream(workspaceId: workspaceID)
        return true
    }

    func controlMoveWorkstream(
        routing: ControlRoutingSelectors,
        workstreamID: UUID,
        toIndex: Int?,
        beforeWorkstreamID: UUID?,
        afterWorkstreamID: UUID?
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard tabManager.workstreams.contains(where: { $0.id == workstreamID }) else { return false }
        // Resolve the requested target into a final index: explicit to_index,
        // else relative to a peer's current position.
        let resolvedIndex: Int?
        if let toIndex {
            resolvedIndex = toIndex
        } else if let beforeWorkstreamID,
                  let peer = tabManager.workstreams.firstIndex(where: { $0.id == beforeWorkstreamID }) {
            resolvedIndex = peer
        } else if let afterWorkstreamID,
                  let peer = tabManager.workstreams.firstIndex(where: { $0.id == afterWorkstreamID }) {
            resolvedIndex = peer + 1
        } else {
            resolvedIndex = nil
        }
        guard let resolvedIndex else { return false }
        tabManager.moveWorkstream(id: workstreamID, toIndex: resolvedIndex)
        return true
    }

    func controlEnterWorkstream(
        routing: ControlRoutingSelectors,
        workstreamID: UUID
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard tabManager.workstreams.contains(where: { $0.id == workstreamID }) else { return false }
        tabManager.enterWorkstream(id: workstreamID)
        return true
    }

    func controlExitWorkstreamDrillIn(
        routing: ControlRoutingSelectors
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        tabManager.exitWorkstreamDrillIn()
        return true
    }
}
