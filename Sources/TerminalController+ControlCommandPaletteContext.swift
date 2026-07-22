import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import Foundation

/// App-target witnesses for live command-palette dispatch and parameterized
/// inline VS Code opening.
extension TerminalController: ControlCommandPaletteContext, ControlInlineVSCodeContext {
    func controlCommandPaletteList(
        routing: ControlRoutingSelectors
    ) -> ControlCommandPaletteListResolution {
        guard let (windowID, window) = controlCommandPaletteWindow(routing: routing) else {
            return .windowNotFound
        }
        let request = CommandPaletteControlRequest(operation: .list)
        postCommandPaletteControlRequest(request, to: window)
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
        guard let (windowID, window) = controlCommandPaletteWindow(routing: routing) else {
            return .windowNotFound
        }
        let request = CommandPaletteControlRequest(
            operation: .run(
                commandID: commandID,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        )
        postCommandPaletteControlRequest(request, to: window)
        switch request.result {
        case .ran(let command, let result):
            let item = controlCommandPaletteItem(command)
            switch result {
            case .completed:
                return .completed(windowID: windowID, command: item)
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

    private func controlCommandPaletteWindow(
        routing: ControlRoutingSelectors
    ) -> (windowID: UUID, window: NSWindow)? {
        guard let tabManager = resolveTabManager(routing: routing),
              let app = AppDelegate.shared,
              let windowID = app.windowId(for: tabManager) ?? v2ResolveWindowId(tabManager: tabManager),
              let window = app.mainWindow(for: windowID) else {
            return nil
        }
        return (windowID, window)
    }

    private func postCommandPaletteControlRequest(
        _ request: CommandPaletteControlRequest,
        to window: NSWindow
    ) {
        NotificationCenter.default.post(
            name: .commandPaletteControlRequested,
            object: window,
            userInfo: [CommandPaletteControlRequest.notificationUserInfoKey: request]
        )
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
        if let paneID = routing.paneID,
           let located = v2LocatePane(paneID),
           located.tabManager === tabManager {
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
