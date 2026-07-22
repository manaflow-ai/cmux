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
            missingCommandID: String(
                localized: "socket.palette.error.missingCommandID",
                defaultValue: "Missing 'command_id' parameter"
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
        guard let (windowID, handler) = controlCommandPaletteTarget(routing: routing) else {
            return .windowNotFound
        }
        let request = CommandPaletteControlRequest(operation: .list)
        handler(request)
        guard case .listed(let commands)? = request.result else {
            return .windowNotFound
        }
        return .listed(windowID: windowID, commands: commands.map(controlCommandPaletteItem))
    }

    func controlCommandPaletteRun(
        routing: ControlRoutingSelectors,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?
    ) -> ControlCommandPaletteRunResolution {
        guard let (windowID, handler) = controlCommandPaletteTarget(routing: routing) else {
            return .windowNotFound
        }
        let request = CommandPaletteControlRequest(
            operation: .run(
                commandID: commandID,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        )
        handler(request)
        switch request.result {
        case .ran(let command, let result):
            let item = controlCommandPaletteItem(command)
            switch result {
            case .completed:
                return .completed(windowID: windowID, command: item)
            case .queued:
                return .queued(windowID: windowID, command: item)
            case .dispatched:
                return .dispatched(windowID: windowID, command: item)
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
            return .tabManagerUnavailable
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
        guard AppDelegate.shared?.openDirectoryInInlineVSCode(
            URL(fileURLWithPath: directoryPath, isDirectory: true),
            tabManager: tabManager,
            workspaceID: workspace.id
        ) == true else {
            return .openFailed
        }
        return .accepted(
            windowID: AppDelegate.shared?.windowId(for: tabManager) ?? v2ResolveWindowId(tabManager: tabManager),
            workspaceID: workspace.id
        )
    }

    private func controlCommandPaletteTarget(
        routing: ControlRoutingSelectors
    ) -> (windowID: UUID, handler: (CommandPaletteControlRequest) -> Void)? {
        guard let tabManager = resolveTabManager(routing: routing),
              controlPaletteSelectorsBelongToTarget(routing, tabManager: tabManager),
              let app = AppDelegate.shared,
              let context = app.mainWindowContext(for: tabManager),
              let handler = context.commandPaletteControlHandler else {
            return nil
        }
        return (context.windowId, handler)
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
