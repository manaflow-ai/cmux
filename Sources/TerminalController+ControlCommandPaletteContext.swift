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
        guard TerminalDirectoryOpenTarget.vscodeInline.isAvailable() else {
            return .vscodeUnavailable
        }
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let workspace = controlInlineVSCodeWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
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
              let app = AppDelegate.shared,
              let context = app.mainWindowContext(for: tabManager),
              let handler = context.commandPaletteControlHandler else {
            return nil
        }
        return (context.windowId, handler)
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

    private func controlInlineVSCodeWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let workspaceID = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == workspaceID })
        }
        if let surfaceID = routing.surfaceID {
            return tabManager.tabs.first(where: { $0.panels[surfaceID] != nil })
        }
        if let paneID = routing.paneID {
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
}
