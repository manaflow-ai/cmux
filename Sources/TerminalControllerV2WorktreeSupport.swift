import AppKit
import Bonsplit
import Foundation

private enum AsyncWorktreeV2Message {
    static let tabManagerUnavailable = String(localized: "error.socket.tabManagerUnavailable", defaultValue: "TabManager not available")
    static let cwdMustBeString = String(localized: "error.socket.cwdMustBeString", defaultValue: "cwd must be a string")
    static let invalidDirection = String(localized: "socket.surfaceSplitOff.error.invalidDirection", defaultValue: "Missing or invalid direction (left|right|up|down)")
    static let workspaceNotFound = String(localized: "error.socket.workspaceNotFound", defaultValue: "Workspace not found")
    static let surfaceNotFound = String(localized: "error.socket.surfaceNotFound", defaultValue: "Surface not found")
    static let noFocusedSurface = String(localized: "error.socket.noFocusedSurface", defaultValue: "No focused surface")
    static let paneNotFound = String(localized: "error.socket.paneNotFound", defaultValue: "Pane not found")
    static let noSourceSurfaceToSplit = String(localized: "error.socket.noSourceSurfaceToSplit", defaultValue: "No source surface to split")
    static let failedToCreateSplit = String(localized: "error.socket.failedToCreateSplit", defaultValue: "Failed to create split")
    static let failedToCreateSurface = String(localized: "error.socket.failedToCreateSurface", defaultValue: "Failed to create surface")
    static let failedToCreatePane = String(localized: "error.socket.failedToCreatePane", defaultValue: "Failed to create pane")
}

@MainActor
extension TerminalController {
    private func v2CreateEphemeralWorktreeIfRequestedAsync(
        params: [String: Any],
        panelType: PanelType,
        sourceDirectory: String?
    ) async -> (record: EphemeralWorktreeRecord?, workingDirectory: String?, error: V2CallResult?) {
        let options = v2EphemeralWorktreeOptions(params: params, panelType: panelType)
        if let error = options.error {
            return (nil, nil, error)
        }
        guard options.enabled else {
            return (nil, nil, nil)
        }
        guard let sourceDirectory = sourceDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceDirectory.isEmpty else {
            return (
                nil,
                nil,
                .err(
                    code: "invalid_params",
                    message: String(
                        localized: "error.ephemeralWorktree.sourceDirectoryRequired",
                        defaultValue: "worktree mode requires a source git repository directory"
                    ),
                    data: nil
                )
            )
        }

        do {
            let policy = options.policy
            let record = try await Task.detached(priority: .utility) {
                try EphemeralWorktreeRegistry.shared.create(
                    sourceDirectory: sourceDirectory,
                    cleanupPolicy: policy
                )
            }.value
            return (record, record.worktreePath, nil)
        } catch {
            return (
                nil,
                nil,
                .err(
                    code: "worktree_error",
                    message: String(
                        localized: "error.ephemeralWorktree.operationFailed",
                        defaultValue: "Failed to create ephemeral worktree."
                    ),
                    data: nil
                )
            )
        }
    }

    private func v2AsyncWorktreeTerminalOnlyError(
        params: [String: Any],
        panelType: PanelType
    ) -> V2CallResult {
        v2EphemeralWorktreeOptions(params: params, panelType: panelType).error
            ?? .err(
                code: "invalid_params",
                message: String(
                    localized: "error.ephemeralWorktree.terminalOnly",
                    defaultValue: "worktree mode is only supported for terminal panes"
                ),
                data: nil
            )
    }

    private func cleanupUnattachedAsyncWorktree(_ record: EphemeralWorktreeRecord?) {
        if let record {
            EphemeralWorktreeRegistry.shared.cleanupInBackground(record, userConfirmed: true)
        }
    }

    private func v2AsyncWorktreeFocusAllowed(
        params: [String: Any],
        allowsFocusMutation: Bool
    ) -> Bool {
        allowsFocusMutation && (v2Bool(params, "focus") ?? false)
    }

    private func v2AsyncWorktreeMaybeFocusWindow(
        for tabManager: TabManager,
        allowsFocusMutation: Bool
    ) {
        guard allowsFocusMutation,
              let windowId = v2ResolveWindowId(tabManager: tabManager) else { return }
        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
        setActiveTabManager(tabManager)
    }

    private func v2AsyncWorktreeMaybeSelectWorkspace(
        _ tabManager: TabManager,
        workspace: Workspace,
        allowsFocusMutation: Bool
    ) {
        guard allowsFocusMutation else { return }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }

    func v2WorkspaceCreateWithAsyncWorktree(
        params: [String: Any],
        allowsFocusMutation: Bool
    ) async -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: AsyncWorktreeV2Message.tabManagerUnavailable, data: nil)
        }

        let requestedWorkingDirectory = v2RawString(params, "working_directory")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = (requestedWorkingDirectory?.isEmpty == false) ? requestedWorkingDirectory : nil

        let requestedInitialCommand = v2RawString(params, "initial_command")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil

        let rawInitialEnv = v2StringMap(params, "initial_env") ?? [:]
        let initialEnv = rawInitialEnv.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = pair.value
        }
        let cwd: String?
        if let workingDirectory {
            cwd = workingDirectory
        } else if let raw = params["cwd"] {
            guard let str = raw as? String else {
                return .err(code: "invalid_params", message: AsyncWorktreeV2Message.cwdMustBeString, data: nil)
            }
            cwd = str
        } else {
            cwd = nil
        }

        if v2Bool(params, "worktree") == true, params["layout"] != nil {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "error.ephemeralWorktree.layoutUnsupported",
                    defaultValue: "worktree mode is not supported with workspace layouts yet"
                ),
                data: nil
            )
        }

        let sourceDirectoryForWorktree = tabManager.resolvedWorkingDirectoryForNewWorkspace(override: cwd)
        let worktree = await v2CreateEphemeralWorktreeIfRequestedAsync(
            params: params,
            panelType: .terminal,
            sourceDirectory: sourceDirectoryForWorktree
        )
        if let error = worktree.error {
            return error
        }
        let creationCwd = worktree.workingDirectory ?? cwd

        let requestedTitle = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (requestedTitle?.isEmpty == false) ? requestedTitle : nil
        let description = v2RawString(params, "description")

        let shouldFocus = v2AsyncWorktreeFocusAllowed(
            params: params,
            allowsFocusMutation: allowsFocusMutation
        )
        let ws = tabManager.addWorkspace(
            title: title,
            workingDirectory: creationCwd,
            initialTerminalCommand: initialCommand,
            initialTerminalEnvironment: initialEnv,
            select: shouldFocus,
            eagerLoadTerminal: !shouldFocus,
            initialEphemeralWorktree: worktree.record
        )
        ws.setCustomDescription(description)

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        var payload: [String: Any] = [
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": ws.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id)
        ]
        payload.merge(v2EphemeralWorktreePayload(worktree.record)) { _, new in new }
        return .ok(payload)
    }

    func v2SurfaceSplitWithAsyncWorktree(
        params: [String: Any],
        allowsFocusMutation: Bool
    ) async -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: AsyncWorktreeV2Message.tabManagerUnavailable, data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: AsyncWorktreeV2Message.invalidDirection, data: nil)
        }
        let panelType = v2PanelType(params, "type") ?? .terminal
        let workingDirectory = v2OptionalTrimmedRawString(params, "working_directory")
        let initialCommand = v2OptionalTrimmedRawString(params, "initial_command")
        let tmuxStartCommand = v2OptionalTrimmedRawString(params, "tmux_start_command")
        let parsedInitialDivider = v2InitialDividerPosition(params)
        if let error = parsedInitialDivider.error {
            return error
        }
        let initialDividerPosition = parsedInitialDivider.value

        guard panelType == .terminal else {
            return v2AsyncWorktreeTerminalOnlyError(params: params, panelType: panelType)
        }
        guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .err(code: "not_found", message: AsyncWorktreeV2Message.workspaceNotFound, data: nil)
        }
        if let invalidSurfaceId = v2InvalidExplicitUUIDParamError(params, key: "surface_id") {
            return invalidSurfaceId
        }
        let requestedSurfaceId: UUID? = v2UUID(params, "surface_id")
        let targetSurfaceId: UUID?
        if let requestedSurfaceId {
            guard ws.panels[requestedSurfaceId] != nil else {
                return .err(code: "not_found", message: AsyncWorktreeV2Message.surfaceNotFound, data: ["surface_id": requestedSurfaceId.uuidString])
            }
            targetSurfaceId = requestedSurfaceId
        } else {
            targetSurfaceId = ws.focusedPanelId
        }
        guard let targetSurfaceId, ws.panels[targetSurfaceId] != nil else {
            return .err(code: "not_found", message: AsyncWorktreeV2Message.noFocusedSurface, data: nil)
        }

        let sourceDirectory = ws.resolvedWorkingDirectoryForNewTerminalSplit(
            from: targetSurfaceId,
            workingDirectory: workingDirectory
        )
        let context = (workspaceId: ws.id, targetSurfaceId: targetSurfaceId, sourceDirectory: sourceDirectory)
        let worktree = await v2CreateEphemeralWorktreeIfRequestedAsync(
            params: params,
            panelType: panelType,
            sourceDirectory: context.sourceDirectory
        )
        if let error = worktree.error {
            return error
        }

        guard let currentWorkspace = tabManager.tabs.first(where: { $0.id == context.workspaceId }) else {
            cleanupUnattachedAsyncWorktree(worktree.record)
            return .err(code: "not_found", message: AsyncWorktreeV2Message.workspaceNotFound, data: nil)
        }
        guard currentWorkspace.panels[context.targetSurfaceId] != nil else {
            cleanupUnattachedAsyncWorktree(worktree.record)
            return .err(code: "not_found", message: AsyncWorktreeV2Message.surfaceNotFound, data: ["surface_id": context.targetSurfaceId.uuidString])
        }
        v2AsyncWorktreeMaybeFocusWindow(for: tabManager, allowsFocusMutation: allowsFocusMutation)
        v2AsyncWorktreeMaybeSelectWorkspace(
            tabManager,
            workspace: currentWorkspace,
            allowsFocusMutation: allowsFocusMutation
        )

        let focus = v2AsyncWorktreeFocusAllowed(
            params: params,
            allowsFocusMutation: allowsFocusMutation
        )
        guard let newId = tabManager.newSplit(
            tabId: currentWorkspace.id,
            surfaceId: context.targetSurfaceId,
            direction: direction,
            focus: focus,
            workingDirectory: worktree.workingDirectory ?? workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialDividerPosition: initialDividerPosition.map { CGFloat($0) },
            ephemeralWorktree: worktree.record
        ) else {
            cleanupUnattachedAsyncWorktree(worktree.record)
            return .err(code: "internal_error", message: AsyncWorktreeV2Message.failedToCreateSplit, data: nil)
        }

        let paneUUID = currentWorkspace.paneId(forPanelId: newId)?.id
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        var payload: [String: Any] = [
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": currentWorkspace.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: currentWorkspace.id),
            "pane_id": v2OrNull(paneUUID?.uuidString),
            "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
            "surface_id": newId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: newId),
            "type": v2OrNull(currentWorkspace.panels[newId]?.panelType.rawValue)
        ]
        payload.merge(v2EphemeralWorktreePayload(worktree.record)) { _, new in new }
        return .ok(payload)
    }

    func v2SurfaceCreateWithAsyncWorktree(
        params: [String: Any],
        allowsFocusMutation: Bool
    ) async -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: AsyncWorktreeV2Message.tabManagerUnavailable, data: nil)
        }

        let panelType = v2PanelType(params, "type") ?? .terminal
        let workingDirectory = v2OptionalTrimmedRawString(params, "working_directory")
        let initialCommand = v2OptionalTrimmedRawString(params, "initial_command")
        let tmuxStartCommand = v2OptionalTrimmedRawString(params, "tmux_start_command")

        guard panelType == .terminal else {
            return v2AsyncWorktreeTerminalOnlyError(params: params, panelType: panelType)
        }
        guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .err(code: "not_found", message: AsyncWorktreeV2Message.workspaceNotFound, data: nil)
        }
        if let invalidPaneId = v2InvalidExplicitUUIDParamError(params, key: "pane_id") {
            return invalidPaneId
        }
        let paneUUID = v2UUID(params, "pane_id")
        let paneId: PaneID? = {
            if let paneUUID {
                return ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID })
            }
            return ws.bonsplitController.focusedPaneId
        }()
        guard let paneId else {
            return .err(code: "not_found", message: AsyncWorktreeV2Message.paneNotFound, data: nil)
        }

        let sourceDirectory = ws.resolvedWorkingDirectoryForNewTerminalSurface(
            inPane: paneId,
            workingDirectory: workingDirectory
        )
        let context = (workspaceId: ws.id, paneId: paneId, sourceDirectory: sourceDirectory)
        let worktree = await v2CreateEphemeralWorktreeIfRequestedAsync(
            params: params,
            panelType: panelType,
            sourceDirectory: context.sourceDirectory
        )
        if let error = worktree.error {
            return error
        }

        guard let currentWorkspace = tabManager.tabs.first(where: { $0.id == context.workspaceId }) else {
            cleanupUnattachedAsyncWorktree(worktree.record)
            return .err(code: "not_found", message: AsyncWorktreeV2Message.workspaceNotFound, data: nil)
        }
        guard currentWorkspace.bonsplitController.allPaneIds.contains(context.paneId) else {
            cleanupUnattachedAsyncWorktree(worktree.record)
            return .err(code: "not_found", message: AsyncWorktreeV2Message.paneNotFound, data: nil)
        }
        v2AsyncWorktreeMaybeFocusWindow(for: tabManager, allowsFocusMutation: allowsFocusMutation)
        v2AsyncWorktreeMaybeSelectWorkspace(
            tabManager,
            workspace: currentWorkspace,
            allowsFocusMutation: allowsFocusMutation
        )

        let focus = v2AsyncWorktreeFocusAllowed(
            params: params,
            allowsFocusMutation: allowsFocusMutation
        )
        guard let newPanelId = currentWorkspace.newTerminalSurface(
            inPane: context.paneId,
            focus: focus,
            workingDirectory: worktree.workingDirectory ?? workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            ephemeralWorktree: worktree.record
        )?.id else {
            cleanupUnattachedAsyncWorktree(worktree.record)
            return .err(code: "internal_error", message: AsyncWorktreeV2Message.failedToCreateSurface, data: nil)
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        var payload: [String: Any] = [
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": currentWorkspace.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: currentWorkspace.id),
            "pane_id": context.paneId.id.uuidString,
            "pane_ref": v2Ref(kind: .pane, uuid: context.paneId.id),
            "surface_id": newPanelId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: newPanelId),
            "type": panelType.rawValue
        ]
        payload.merge(v2EphemeralWorktreePayload(worktree.record)) { _, new in new }
        return .ok(payload)
    }

    func v2PaneCreateWithAsyncWorktree(
        params: [String: Any],
        allowsFocusMutation: Bool
    ) async -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: AsyncWorktreeV2Message.tabManagerUnavailable, data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: AsyncWorktreeV2Message.invalidDirection, data: nil)
        }

        let panelType = v2PanelType(params, "type") ?? .terminal
        let workingDirectory = v2OptionalTrimmedRawString(params, "working_directory")
        let initialCommand = v2OptionalTrimmedRawString(params, "initial_command")
        let tmuxStartCommand = v2OptionalTrimmedRawString(params, "tmux_start_command")
        let orientation = direction.orientation
        let insertFirst = direction.insertFirst
        let parsedInitialDivider = v2InitialDividerPosition(params)
        if let error = parsedInitialDivider.error {
            return error
        }
        let initialDividerPosition = parsedInitialDivider.value

        guard panelType == .terminal else {
            return v2AsyncWorktreeTerminalOnlyError(params: params, panelType: panelType)
        }
        guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .err(code: "not_found", message: AsyncWorktreeV2Message.workspaceNotFound, data: nil)
        }
        if let invalidSurfaceId = v2InvalidExplicitUUIDParamError(params, key: "surface_id") {
            return invalidSurfaceId
        }
        let requestedPanelId = v2UUID(params, "surface_id")
        guard let sourcePanelId = requestedPanelId ?? ws.focusedPanelId,
              ws.panels[sourcePanelId] != nil else {
            return .err(code: "not_found", message: AsyncWorktreeV2Message.noSourceSurfaceToSplit, data: nil)
        }

        let sourceDirectory = ws.resolvedWorkingDirectoryForNewTerminalSplit(
            from: sourcePanelId,
            workingDirectory: workingDirectory
        )
        let context = (workspaceId: ws.id, sourcePanelId: sourcePanelId, sourceDirectory: sourceDirectory)
        let worktree = await v2CreateEphemeralWorktreeIfRequestedAsync(
            params: params,
            panelType: panelType,
            sourceDirectory: context.sourceDirectory
        )
        if let error = worktree.error {
            return error
        }

        guard let currentWorkspace = tabManager.tabs.first(where: { $0.id == context.workspaceId }) else {
            cleanupUnattachedAsyncWorktree(worktree.record)
            return .err(code: "not_found", message: AsyncWorktreeV2Message.workspaceNotFound, data: nil)
        }
        guard currentWorkspace.panels[context.sourcePanelId] != nil else {
            cleanupUnattachedAsyncWorktree(worktree.record)
            return .err(code: "not_found", message: AsyncWorktreeV2Message.noSourceSurfaceToSplit, data: nil)
        }
        v2AsyncWorktreeMaybeFocusWindow(for: tabManager, allowsFocusMutation: allowsFocusMutation)
        v2AsyncWorktreeMaybeSelectWorkspace(
            tabManager,
            workspace: currentWorkspace,
            allowsFocusMutation: allowsFocusMutation
        )

        let focus = v2AsyncWorktreeFocusAllowed(
            params: params,
            allowsFocusMutation: allowsFocusMutation
        )
        guard let newPanelId = currentWorkspace.newTerminalSplit(
            from: context.sourcePanelId,
            orientation: orientation,
            insertFirst: insertFirst,
            focus: focus,
            workingDirectory: worktree.workingDirectory ?? workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialDividerPosition: initialDividerPosition.map { CGFloat($0) },
            ephemeralWorktree: worktree.record
        )?.id else {
            cleanupUnattachedAsyncWorktree(worktree.record)
            return .err(code: "internal_error", message: AsyncWorktreeV2Message.failedToCreatePane, data: nil)
        }

        let paneUUID = currentWorkspace.paneId(forPanelId: newPanelId)?.id
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        var payload: [String: Any] = [
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": currentWorkspace.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: currentWorkspace.id),
            "pane_id": v2OrNull(paneUUID?.uuidString),
            "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
            "surface_id": newPanelId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: newPanelId),
            "type": panelType.rawValue
        ]
        payload.merge(v2EphemeralWorktreePayload(worktree.record)) { _, new in new }
        return .ok(payload)
    }
}
