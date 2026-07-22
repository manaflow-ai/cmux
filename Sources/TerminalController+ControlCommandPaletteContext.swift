import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import Foundation

/// App-target witnesses for live command-palette dispatch and parameterized
/// inline VS Code opening.
extension TerminalController: ControlCommandPaletteContext, ControlInlineVSCodeContext {
    func controlCommandPaletteStrings() -> ControlCommandPaletteStrings {
        ControlCommandPaletteStrings(
            windowNotFound: String(
                localized: "socket.palette.error.windowNotFound",
                defaultValue: "Command palette window not found"
            ),
            targetUnavailable: String(
                localized: "socket.palette.error.targetUnavailable",
                defaultValue: "The command palette target is no longer available"
            ),
            missingCommandID: String(
                localized: "socket.palette.error.missingCommandID",
                defaultValue: "Missing 'command_id' parameter"
            ),
            invalidTarget: String(
                localized: "socket.palette.error.invalidTarget",
                defaultValue: "Invalid command palette target"
            ),
            argumentsMustBeStringObject: String(
                localized: "socket.palette.error.argumentsObject",
                defaultValue: "'arguments' must be an object of string values"
            ),
            commandNotFound: String(
                localized: "socket.palette.error.commandNotFound",
                defaultValue: "Command palette action not found in the current context"
            ),
            missingArgumentsFormat: String(
                localized: "socket.palette.error.missingArguments",
                defaultValue: "Missing required action arguments: %@"
            ),
            unknownArgumentsFormat: String(
                localized: "socket.palette.error.unknownArguments",
                defaultValue: "Unknown action arguments: %@"
            ),
            invalidArgumentValuesFormat: String(
                localized: "socket.palette.error.invalidArgumentValues",
                defaultValue: "Invalid values for action arguments: %@"
            )
        )
    }

    func controlCommandPaletteList(
        routing: ControlRoutingSelectors
    ) -> ControlCommandPaletteListResolution {
        guard let (_, target, handler) = controlCommandPaletteTarget(routing: routing) else {
            return .windowNotFound
        }
        let request = CommandPaletteControlRequest(target: target, operation: .list)
        handler(request)
        guard case .listed(let commands)? = request.result else {
            return .windowNotFound
        }
        return .listed(
            target: ControlCommandPaletteTarget(
                windowID: target.windowID,
                workspaceID: target.workspaceID,
                panelID: target.panelID
            ),
            commands: commands.map(controlCommandPaletteItem)
        )
    }

    func controlCommandPaletteRun(
        routing: ControlRoutingSelectors,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?
    ) -> ControlCommandPaletteRunResolution {
        guard let (windowID, target, handler) = controlCommandPaletteTarget(routing: routing) else {
            return .windowNotFound
        }
        return controlCommandPaletteRun(
            windowID: windowID,
            target: target,
            handler: handler,
            commandID: commandID,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
    }

    func controlCommandPaletteRun(
        target: ControlCommandPaletteTarget,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?
    ) -> ControlCommandPaletteRunResolution {
        switch controlCommandPaletteTarget(target) {
        case .windowNotFound:
            return .windowNotFound
        case .targetUnavailable:
            return .targetUnavailable
        case .resolved(let windowID, let actionTarget, let handler):
            return controlCommandPaletteRun(
                windowID: windowID,
                target: actionTarget,
                handler: handler,
                commandID: commandID,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        }
    }

    nonisolated func controlInlineVSCodeStrings() -> ControlInlineVSCodeStrings {
        ControlInlineVSCodeStrings(
            missingPath: String(
                localized: "socket.vscode.error.missingPath",
                defaultValue: "Missing 'path' parameter"
            ),
            directoryNotFound: String(
                localized: "socket.vscode.error.directoryNotFound",
                defaultValue: "Directory not found"
            ),
            notDirectory: String(
                localized: "socket.vscode.error.notDirectory",
                defaultValue: "Path is not a directory"
            ),
            tabManagerUnavailable: String(
                localized: "socket.vscode.error.tabManagerUnavailable",
                defaultValue: "The inline editor is unavailable"
            ),
            workspaceNotFound: String(
                localized: "socket.vscode.error.workspaceNotFound",
                defaultValue: "Workspace not found"
            ),
            vscodeUnavailable: String(
                localized: "socket.vscode.error.unavailable",
                defaultValue: "VS Code Inline is unavailable"
            ),
            openFailed: String(
                localized: "socket.vscode.error.openFailed",
                defaultValue: "Failed to open VS Code Inline"
            )
        )
    }

    func controlInlineVSCodeOpen(
        routing: ControlRoutingSelectors,
        directoryPath: String
    ) -> ControlInlineVSCodeOpenResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            let hasExplicitTarget = routing.hasWindowIDParam
                || routing.hasGroupIDParam
                || routing.hasWorkspaceIDParam
                || routing.hasSurfaceIDParam
                || routing.hasPaneIDParam
            return hasExplicitTarget ? .workspaceNotFound : .tabManagerUnavailable
        }
        guard controlPaletteSelectorsBelongToTarget(routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        guard let workspace = controlInlineVSCodeWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        guard TerminalDirectoryOpenTarget.vscodeInline.isAvailable() else {
            return .vscodeUnavailable
        }
        guard let windowID = AppDelegate.shared?.windowId(for: tabManager)
                ?? v2ResolveWindowId(tabManager: tabManager) else {
            return .tabManagerUnavailable
        }
        guard let actionTarget = controlCommandPaletteActionTarget(
            routing: routing,
            tabManager: tabManager,
            windowID: windowID
        ) else {
            return .workspaceNotFound
        }
        guard AppDelegate.shared?.openDirectoryInInlineVSCode(
            URL(fileURLWithPath: directoryPath, isDirectory: true),
            tabManager: tabManager,
            windowID: windowID,
            workspaceID: workspace.id,
            panelID: actionTarget.panelID
        ) == true else {
            return .openFailed
        }
        return .accepted(
            windowID: windowID,
            workspaceID: workspace.id
        )
    }

    private func controlCommandPaletteTarget(
        routing: ControlRoutingSelectors
    ) -> (
        windowID: UUID,
        target: CommandPaletteActionTarget,
        handler: (CommandPaletteControlRequest) -> Void
    )? {
        guard let tabManager = resolveTabManager(routing: routing),
              controlPaletteSelectorsBelongToTarget(routing, tabManager: tabManager),
              let app = AppDelegate.shared,
              let context = app.mainWindowContext(for: tabManager),
              let target = controlCommandPaletteActionTarget(
                routing: routing,
                tabManager: tabManager,
                windowID: context.windowId
              ),
              let handler = context.commandPaletteControlHandler else {
            return nil
        }
        return (context.windowId, target, handler)
    }

    /// Resolves a list-time identity without consulting current focus. Every
    /// component is revalidated so deleted windows, workspaces, or panels fail
    /// closed instead of retargeting the action.
    private func controlCommandPaletteTarget(
        _ target: ControlCommandPaletteTarget
    ) -> ExactCommandPaletteTargetResolution {
        let windowRouting = ControlRoutingSelectors(
            hasWindowIDParam: true,
            windowID: target.windowID,
            groupID: nil,
            workspaceID: nil,
            surfaceID: nil,
            paneID: nil
        )
        guard let tabManager = resolveTabManager(routing: windowRouting),
              let app = AppDelegate.shared,
              let context = app.mainWindowContext(for: tabManager),
              context.windowId == target.windowID else {
            return .windowNotFound
        }
        guard let handler = context.commandPaletteControlHandler else {
            return .targetUnavailable
        }

        if let workspaceID = target.workspaceID {
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                return .targetUnavailable
            }
            if let panelID = target.panelID,
               workspace.panels[panelID] == nil {
                return .targetUnavailable
            }
        } else {
            guard target.panelID == nil, tabManager.tabs.isEmpty else {
                return .targetUnavailable
            }
        }

        return .resolved(
            windowID: context.windowId,
            target: CommandPaletteActionTarget(
                windowID: target.windowID,
                workspaceID: target.workspaceID,
                panelID: target.panelID
            ),
            handler: handler
        )
    }

    private func controlCommandPaletteRun(
        windowID: UUID,
        target: CommandPaletteActionTarget,
        handler: (CommandPaletteControlRequest) -> Void,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?
    ) -> ControlCommandPaletteRunResolution {
        let request = CommandPaletteControlRequest(
            target: target,
            operation: .run(
                commandID: commandID,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        )
        handler(request)
        return controlCommandPaletteRunResolution(request.result, windowID: windowID)
    }

    private func controlCommandPaletteRunResolution(
        _ result: CommandPaletteControlRequest.Result?,
        windowID: UUID
    ) -> ControlCommandPaletteRunResolution {
        switch result {
        case .ran(let command, let result):
            let item = controlCommandPaletteItem(command)
            switch result {
            case .completed:
                return .completed(windowID: windowID, command: item)
            case .queued:
                return .queued(windowID: windowID, command: item)
            case .presented:
                return .presented(windowID: windowID, command: item)
            case .requiresArguments(let arguments):
                return .requiresArguments(
                    windowID: windowID,
                    command: item,
                    arguments: arguments.map(controlCommandPaletteArgument)
                )
            case .invalidArguments(let names):
                return .invalidArguments(windowID: windowID, command: item, names: names)
            case .invalidArgumentValues(let names):
                return .invalidArgumentValues(windowID: windowID, command: item, names: names)
            case .failed(let code, let message):
                return .failed(
                    windowID: windowID,
                    command: item,
                    code: code,
                    message: message
                )
            }
        case .commandNotFound:
            return .commandNotFound
        case .listed, .none:
            return .windowNotFound
        }
    }

    /// Collapses every selector into one immutable workspace/panel identity.
    /// Contradictory selectors fail closed instead of letting a higher-level
    /// window route silently retarget a lower-level action.
    private func controlCommandPaletteActionTarget(
        routing: ControlRoutingSelectors,
        tabManager: TabManager,
        windowID: UUID
    ) -> CommandPaletteActionTarget? {
        var workspaceCandidates: [Workspace] = []
        var explicitPanelID: UUID?
        var groupAnchor: Workspace?

        if routing.hasGroupIDParam {
            guard let groupID = routing.groupID,
                  let group = tabManager.workspaceGroups.first(where: { $0.id == groupID }),
                  let anchor = tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId }) else {
                return nil
            }
            groupAnchor = anchor
        }

        if routing.hasWorkspaceIDParam {
            guard let workspaceID = routing.workspaceID else { return nil }
            let resolution = controlPaletteWorkspaceResolution(
                workspaceID: workspaceID,
                tabManager: tabManager
            )
            guard resolution.belongsToTarget, let workspace = resolution.workspace else { return nil }
            workspaceCandidates.append(workspace)
        }

        if routing.hasSurfaceIDParam {
            guard let surfaceID = routing.surfaceID else { return nil }
            if windowDockContainingPanel(surfaceID) != nil {
                guard let workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first else { return nil }
                workspaceCandidates.append(workspace)
            } else {
                guard let workspace = tabManager.tabs.first(where: { $0.panels[surfaceID] != nil }) else {
                    return nil
                }
                workspaceCandidates.append(workspace)
                explicitPanelID = surfaceID
            }
        }

        if routing.hasPaneIDParam {
            guard let paneID = routing.paneID else { return nil }
            if windowDockContainingPane(paneID) != nil {
                guard let workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first else { return nil }
                workspaceCandidates.append(workspace)
            } else {
                guard let located = v2LocatePane(paneID),
                      located.tabManager === tabManager else {
                    return nil
                }
                if let explicitPanelID {
                    guard located.workspace.paneId(forPanelId: explicitPanelID)?.id == paneID else {
                        return nil
                    }
                } else {
                    guard let panePanelID = located.workspace.effectiveSelectedPanelId(inPane: located.paneId) else {
                        return nil
                    }
                    explicitPanelID = panePanelID
                }
                workspaceCandidates.append(located.workspace)
            }
        }

        let workspace = workspaceCandidates.first
            ?? groupAnchor
            ?? tabManager.selectedWorkspace
            ?? tabManager.tabs.first
        if let workspace,
           workspaceCandidates.contains(where: { $0.id != workspace.id }) {
            return nil
        }
        if let groupID = routing.groupID,
           let workspace,
           workspace.groupId != groupID {
            return nil
        }
        if let explicitPanelID,
           workspace?.panels[explicitPanelID] == nil {
            return nil
        }

        return CommandPaletteActionTarget(
            windowID: windowID,
            workspaceID: workspace?.id,
            panelID: explicitPanelID ?? workspace?.focusedPanelId
        )
    }

    /// Palette actions are window-scoped, but lower-precedence selectors still
    /// have to describe that same window. Without this check, a stale selector
    /// falls through `resolveTabManager` to the caller window, while an explicit
    /// `window_id` can mask a selector owned by another window.
    private func controlPaletteSelectorsBelongToTarget(
        _ routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Bool {
        if routing.hasGroupIDParam {
            guard let groupID = routing.groupID,
                  tabManager.workspaceGroups.contains(where: { $0.id == groupID }) else {
                return false
            }
        }
        if routing.hasWorkspaceIDParam {
            guard let workspaceID = routing.workspaceID else { return false }
            guard controlPaletteWorkspaceResolution(
                workspaceID: workspaceID,
                tabManager: tabManager
            ).belongsToTarget else { return false }
        }
        if routing.hasSurfaceIDParam {
            guard let surfaceID = routing.surfaceID else { return false }
            guard controlTabManager(surfaceID: surfaceID) === tabManager else { return false }
        }
        if routing.hasPaneIDParam {
            guard let paneID = routing.paneID else { return false }
            guard controlTabManager(paneID: paneID) === tabManager else { return false }
        }
        return true
    }

    private func controlCommandPaletteItem(
        _ item: CommandPaletteControlRequest.Item
    ) -> ControlCommandPaletteItem {
        ControlCommandPaletteItem(
            id: item.id,
            title: item.title,
            subtitle: item.subtitle,
            shortcutHint: item.shortcutHint,
            keywords: item.keywords,
            dismissOnRun: item.dismissOnRun,
            arguments: item.arguments.map(controlCommandPaletteArgument)
        )
    }

    private func controlCommandPaletteArgument(
        _ argument: CmuxActionArgumentDefinition
    ) -> ControlCommandPaletteArgument {
        ControlCommandPaletteArgument(
            name: argument.name,
            type: argument.valueType.rawValue,
            required: argument.required,
            allowsEmpty: argument.allowsEmpty
        )
    }

    /// Resolves the main-area workspace used when a palette action needs one.
    /// A terminal in a window Dock exports its Dock owner (the window id) as
    /// `workspace_id`, so that route inherits the owning window's selection.
    func controlInlineVSCodeWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if routing.hasWorkspaceIDParam {
            guard let workspaceID = routing.workspaceID else { return nil }
            let resolution = controlPaletteWorkspaceResolution(
                workspaceID: workspaceID,
                tabManager: tabManager
            )
            guard resolution.belongsToTarget else { return nil }
            return resolution.workspace
        }
        if routing.hasSurfaceIDParam {
            guard let surfaceID = routing.surfaceID else { return nil }
            if let dock = windowDockContainingPanel(surfaceID) {
                return controlPaletteWindowDockWorkspace(dock, tabManager: tabManager)
            }
            return tabManager.tabs.first(where: { $0.panels[surfaceID] != nil })
        }
        if routing.hasPaneIDParam {
            guard let paneID = routing.paneID else { return nil }
            if let dock = windowDockContainingPane(paneID) {
                return controlPaletteWindowDockWorkspace(dock, tabManager: tabManager)
            }
            guard let located = v2LocatePane(paneID),
                  located.tabManager === tabManager else {
                return nil
            }
            return located.workspace
        }
        if routing.hasGroupIDParam {
            guard let groupID = routing.groupID,
                  let group = tabManager.workspaceGroups.first(where: { $0.id == groupID }) else {
                return nil
            }
            return tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId })
        }
        if let selected = tabManager.selectedWorkspace {
            return selected
        }
        if let first = tabManager.tabs.first {
            return first
        }
        return tabManager.addWorkspace(select: true)
    }

    /// Resolves both real workspace ids and the two window-Dock routing forms.
    /// Keeping selector validation and workspace selection on this one path
    /// prevents a route from validating as a Dock owner and then failing when
    /// an action asks for the owning window's main-area workspace.
    private func controlPaletteWorkspaceResolution(
        workspaceID: UUID,
        tabManager: TabManager
    ) -> (belongsToTarget: Bool, workspace: Workspace?) {
        if workspaceID == AppDelegate.windowDockAliasWorkspaceId {
            return (true, tabManager.selectedWorkspace ?? tabManager.tabs.first)
        }
        if let dockOwner = AppDelegate.shared?.tabManagerForWindowDockOwner(workspaceID) {
            guard dockOwner === tabManager else { return (false, nil) }
            return (true, tabManager.selectedWorkspace ?? tabManager.tabs.first)
        }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return (false, nil)
        }
        return (true, workspace)
    }

    /// A window-Dock surface or pane inherits the owning window's main-area
    /// workspace. Verify the owner identity so a contradictory explicit window
    /// cannot redirect a Dock selector into another window.
    private func controlPaletteWindowDockWorkspace(
        _ dock: DockSplitStore,
        tabManager: TabManager
    ) -> Workspace? {
        guard AppDelegate.shared?.tabManagerForWindowDockOwner(dock.workspaceId) === tabManager else {
            return nil
        }
        return tabManager.selectedWorkspace ?? tabManager.tabs.first
    }
}

@MainActor
private enum ExactCommandPaletteTargetResolution {
    case windowNotFound
    case targetUnavailable
    case resolved(
        windowID: UUID,
        target: CommandPaletteActionTarget,
        handler: (CommandPaletteControlRequest) -> Void
    )
}
