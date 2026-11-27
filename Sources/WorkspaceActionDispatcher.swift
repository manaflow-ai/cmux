import Foundation

enum WorkspaceActionDispatcher {
    struct PinResolutionContext {
        let workspacesById: [UUID: Workspace]
        let liveWorkspaceIds: Set<UUID>

        @MainActor
        init(workspaces: [Workspace]) {
            self.init(
                workspacesById: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
                liveWorkspaceIds: Set(workspaces.map(\.id))
            )
        }

        init(workspacesById: [UUID: Workspace], liveWorkspaceIds: Set<UUID>) {
            self.workspacesById = workspacesById
            self.liveWorkspaceIds = liveWorkspaceIds
        }
    }

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
        pinState(in: PinResolutionContext(workspaces: tabManager.tabs), target: target)
    }

    @MainActor
    static func pinState(
        in context: PinResolutionContext,
        target: Target
    ) -> PinState? {
        let targetWorkspaceIds = liveWorkspaceIds(in: context, from: target.workspaceIds)
        guard !targetWorkspaceIds.isEmpty else { return nil }

        let anchorWorkspaceId = target.anchorWorkspaceId.flatMap { anchorId in
            context.workspacesById[anchorId] == nil ? nil : anchorId
        } ?? targetWorkspaceIds[0]

        guard let anchorWorkspace = context.workspacesById[anchorWorkspaceId] else {
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
        let changedWorkspaceIds = tabManager.setPinned(
            workspaceIds: targetWorkspaceIds,
            pinned: state.pinned
        )

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
        liveWorkspaceIds(in: Set(tabManager.tabs.map(\.id)), from: workspaceIds)
    }

    private static func liveWorkspaceIds(
        in context: PinResolutionContext,
        from workspaceIds: [UUID]
    ) -> [UUID] {
        liveWorkspaceIds(in: context.liveWorkspaceIds, from: workspaceIds)
    }

    private static func liveWorkspaceIds(
        in liveWorkspaceIds: Set<UUID>,
        from workspaceIds: [UUID]
    ) -> [UUID] {
        var seen = Set<UUID>()
        var resolved: [UUID] = []

        for workspaceId in workspaceIds where liveWorkspaceIds.contains(workspaceId) && !seen.contains(workspaceId) {
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
