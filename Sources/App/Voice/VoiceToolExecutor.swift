import Foundation
import AppKit

@MainActor
final class VoiceToolExecutor {
    init() {}

    private var activeTabManager: TabManager? {
        AppDelegate.shared?.activeTabManagerForCommands(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    func execute(call: VoiceToolCall) -> String {
        guard let tabManager = activeTabManager else {
            return #"{"ok":false,"error":"no active window"}"#
        }
        switch call.name {
        case "get_app_state":
            return getAppState(tabManager: tabManager)
        case "switch_workspace":
            return switchWorkspace(args: call.arguments, tabManager: tabManager)
        case "switch_tab":
            return switchTab(args: call.arguments, tabManager: tabManager)
        case "type_text":
            return typeText(args: call.arguments, tabManager: tabManager)
        case "execute_command":
            return executeCommand(args: call.arguments, tabManager: tabManager)
        case "create_workspace":
            return createWorkspace(args: call.arguments, tabManager: tabManager)
        case "close_workspace":
            return closeWorkspace(args: call.arguments, tabManager: tabManager)
        case "rename_workspace":
            return renameWorkspace(args: call.arguments, tabManager: tabManager)
        default:
            return #"{"ok":false,"error":"unknown tool"}"#
        }
    }

    // MARK: - Tool implementations

    private func getAppState(tabManager: TabManager) -> String {
        struct WorkspaceSnapshot: Encodable {
            let id: String
            let title: String
            let isActive: Bool
        }
        let snapshots = tabManager.tabs.map {
            WorkspaceSnapshot(
                id: $0.id.uuidString,
                title: $0.customTitle ?? $0.title,
                isActive: $0.id == tabManager.selectedWorkspace?.id
            )
        }
        struct StateResult: Encodable {
            let workspaces: [WorkspaceSnapshot]
            let activeWorkspaceId: String?
        }
        let result = StateResult(
            workspaces: snapshots,
            activeWorkspaceId: tabManager.selectedWorkspace?.id.uuidString
        )
        return (try? String(data: JSONEncoder().encode(result), encoding: .utf8)) ?? #"{"ok":false}"#
    }

    private func switchWorkspace(args: String, tabManager: TabManager) -> String {
        guard let id = parseStringArg("id", from: args),
              let uuid = UUID(uuidString: id),
              let workspace = tabManager.tabs.first(where: { $0.id == uuid })
        else {
            return #"{"ok":false,"error":"workspace not found"}"#
        }
        tabManager.selectWorkspace(workspace)
        return #"{"ok":true}"#
    }

    private func switchTab(args: String, tabManager: TabManager) -> String {
        guard let id = parseStringArg("id", from: args),
              let uuid = UUID(uuidString: id),
              let tab = tabManager.tabs.first(where: { $0.id == uuid })
        else {
            return #"{"ok":false,"error":"tab not found"}"#
        }
        tabManager.selectTab(tab)
        return #"{"ok":true}"#
    }

    private func typeText(args: String, tabManager: TabManager) -> String {
        guard let text = parseStringArg("text", from: args),
              let panel = tabManager.selectedTerminalPanel
        else {
            return #"{"ok":false,"error":"no active terminal"}"#
        }
        panel.sendText(text)
        return #"{"ok":true}"#
    }

    private func executeCommand(args: String, tabManager: TabManager) -> String {
        guard let command = parseStringArg("command", from: args),
              let panel = tabManager.selectedTerminalPanel
        else {
            return #"{"ok":false,"error":"no active terminal"}"#
        }
        panel.sendInput(command + "\n")
        return #"{"ok":true}"#
    }

    private func createWorkspace(args: String, tabManager: TabManager) -> String {
        let workspace = tabManager.addTab()
        if let name = parseStringArg("name", from: args), !name.isEmpty {
            tabManager.setCustomTitle(tabId: workspace.id, title: name)
        }
        return #"{"ok":true,"id":"\#(workspace.id.uuidString)"}"#
    }

    private func closeWorkspace(args: String, tabManager: TabManager) -> String {
        let workspace: Workspace?
        if let id = parseStringArg("id", from: args), let uuid = UUID(uuidString: id) {
            workspace = tabManager.tabs.first(where: { $0.id == uuid })
        } else {
            workspace = tabManager.selectedWorkspace
        }
        guard let workspace else {
            return #"{"ok":false,"error":"workspace not found"}"#
        }
        tabManager.closeWorkspace(workspace)
        return #"{"ok":true}"#
    }

    private func renameWorkspace(args: String, tabManager: TabManager) -> String {
        guard let id = parseStringArg("id", from: args),
              let uuid = UUID(uuidString: id),
              let name = parseStringArg("name", from: args)
        else {
            return #"{"ok":false,"error":"id and name required"}"#
        }
        guard tabManager.tabs.contains(where: { $0.id == uuid }) else {
            return #"{"ok":false,"error":"workspace not found"}"#
        }
        tabManager.setCustomTitle(tabId: uuid, title: name)
        return #"{"ok":true}"#
    }

    // MARK: - Helpers

    private func parseStringArg(_ key: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = dict[key] as? String
        else { return nil }
        return value
    }
}
