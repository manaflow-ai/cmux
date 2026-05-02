import Foundation

enum WorkspaceActionDispatcher {
    struct Target: Equatable {
        let workspaceIds: [UUID]
        let anchorWorkspaceId: UUID?

        init(workspaceIds: [UUID], anchorWorkspaceId: UUID?) {
            self.workspaceIds = workspaceIds
            self.anchorWorkspaceId = anchorWorkspaceId
        }

        static func single(_ workspaceId: UUID) -> Target {
            Target(workspaceIds: [workspaceId], anchorWorkspaceId: workspaceId)
        }
    }

    struct PinState: Equatable {
        let targetWorkspaceIds: [UUID]
        let anchorWorkspaceId: UUID
        let pinned: Bool
    }

    struct PinResult: Equatable {
        let targetWorkspaceIds: [UUID]
        let changedWorkspaceIds: [UUID]
        let pinned: Bool
    }

    @MainActor
    static func pinState(
        in tabManager: TabManager,
        target: Target
    ) -> PinState? {
        let targetWorkspaceIds = liveWorkspaceIds(in: tabManager, from: target.workspaceIds)
        guard !targetWorkspaceIds.isEmpty else { return nil }

        let anchorWorkspaceId = target.anchorWorkspaceId.flatMap { anchorId in
            tabManager.tabs.contains { $0.id == anchorId } ? anchorId : nil
        } ?? targetWorkspaceIds[0]

        guard let anchorWorkspace = tabManager.tabs.first(where: { $0.id == anchorWorkspaceId }) else {
            return nil
        }

        return PinState(
            targetWorkspaceIds: targetWorkspaceIds,
            anchorWorkspaceId: anchorWorkspaceId,
            pinned: !anchorWorkspace.isPinned
        )
    }

    @discardableResult
    @MainActor
    static func performPinAction(
        in tabManager: TabManager,
        target: Target
    ) -> PinResult? {
        guard let state = pinState(in: tabManager, target: target) else { return nil }
        return performPinAction(state, in: tabManager)
    }

    @discardableResult
    @MainActor
    static func performPinAction(
        _ state: PinState,
        in tabManager: TabManager
    ) -> PinResult {
        let targetWorkspaceIds = liveWorkspaceIds(in: tabManager, from: state.targetWorkspaceIds)
        var changedWorkspaceIds: [UUID] = []

        for workspaceId in targetWorkspaceIds {
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { continue }
            let wasPinned = workspace.isPinned
            tabManager.setPinned(workspace, pinned: state.pinned)
            if wasPinned != state.pinned {
                changedWorkspaceIds.append(workspaceId)
            }
        }

        return PinResult(
            targetWorkspaceIds: targetWorkspaceIds,
            changedWorkspaceIds: changedWorkspaceIds,
            pinned: state.pinned
        )
    }

    @MainActor
    private static func liveWorkspaceIds(
        in tabManager: TabManager,
        from workspaceIds: [UUID]
    ) -> [UUID] {
        var seen = Set<UUID>()
        let liveIds = Set(tabManager.tabs.map(\.id))
        var resolved: [UUID] = []

        for workspaceId in workspaceIds where liveIds.contains(workspaceId) && !seen.contains(workspaceId) {
            seen.insert(workspaceId)
            resolved.append(workspaceId)
        }

        return resolved
    }
}

enum WorkspacePinCommands {
    @MainActor
    static func selectedWorkspacePinState(in manager: TabManager) -> WorkspaceActionDispatcher.PinState? {
        guard let workspace = manager.selectedWorkspace else { return nil }
        return WorkspaceActionDispatcher.pinState(in: manager, target: .single(workspace.id))
    }

    @discardableResult
    @MainActor
    static func toggleSelectedWorkspace(in manager: TabManager) -> Bool {
        guard let pinState = selectedWorkspacePinState(in: manager) else { return false }
        let result = WorkspaceActionDispatcher.performPinAction(pinState, in: manager)
        return !result.targetWorkspaceIds.isEmpty
    }

    @MainActor
    static func selectedWorkspaceMenuLabel(
        in manager: TabManager,
        pinState: WorkspaceActionDispatcher.PinState? = nil
    ) -> String {
        guard let workspace = manager.selectedWorkspace else {
            return singleWorkspaceMenuLabel(shouldPin: true)
        }
        let pinState = pinState ?? WorkspaceActionDispatcher.pinState(in: manager, target: .single(workspace.id))
        return singleWorkspaceMenuLabel(shouldPin: pinState?.pinned ?? !workspace.isPinned)
    }

    static func singleWorkspaceMenuLabel(shouldPin: Bool) -> String {
        shouldPin
            ? String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace")
            : String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace")
    }
}
