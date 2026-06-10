import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Window, workspace, tab, and SSH session command dispatch
extension CMUXCLI {
    /// Handles window, workspace, tab, and SSH/VM-attach socket commands.
    /// Returns true when the command matched; false to let the next dispatcher try.
    func runWindowWorkspaceCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowId: String?
    ) throws -> Bool {
        switch command {
        case "list-windows":
            let response = try sendV1Command("list_windows", client: client)
            if jsonOutput {
                let windows = parseWindows(response)
                let payload = windows.map { item -> [String: Any] in
                    var dict: [String: Any] = [
                        "index": item.index,
                        "id": item.id,
                        "key": item.key,
                        "workspace_count": item.workspaceCount,
                    ]
                    dict["selected_workspace_id"] = item.selectedWorkspaceId ?? NSNull()
                    return dict
                }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "current-window":
            let response = try sendV1Command("current_window", client: client)
            if jsonOutput {
                print(jsonString(["window_id": response]))
            } else {
                print(response)
            }

        case "new-window":
            let response = try sendV1Command("new_window", client: client)
            print(response)

        case "focus-window":
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "focus-window requires --window")
            }
            let response = try sendV1Command("focus_window \(target)", client: client)
            print(response)

        case "close-window":
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "close-window requires --window")
            }
            let response = try sendV1Command("close_window \(target)", client: client)
            print(response)

        case "move-workspace-to-window":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "move-workspace-to-window requires --workspace")
            }
            guard let windowRaw = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "move-workspace-to-window requires --window")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let payload = try client.sendV2(method: "workspace.move_to_window", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace", "window"]))

        case "move-surface":
            try runMoveSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "split-off":
            try runSplitOff(commandName: "split-off", commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-surface":
            try runReorderSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-workspace":
            try runReorderWorkspace(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-workspaces":
            try runReorderWorkspaces(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "simulate-sidebar-drag":
            try runSimulateSidebarDrag(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "workspace-action":
            try runWorkspaceAction(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)
        case "tab-action":
            try runTabAction(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)
        case "move-tab-to-new-workspace", "detach-tab":
            try runMoveTabToNewWorkspace(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)
        case "rename-tab":
            try runRenameTab(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "workspace-group":
            try runWorkspaceGroup(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "workspace":
            try runWorkspaceNamespace(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "list-workspaces":
            Self.warnLegacyVerbDeprecated("list-workspaces", replacement: "cmux workspace list")
            try runWorkspaceListCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "ssh":
            try runSSH(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )
        case "ssh-pty-attach":
            try runSSHPTYAttach(commandArgs: commandArgs, client: client)
        case "ssh-session-list":
            try runSSHSessionList(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "ssh-session-attach":
            try runSSHSessionAttach(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "ssh-session-cleanup":
            try runSSHSessionCleanup(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "ssh-session-end":
            try runSSHSessionEnd(commandArgs: commandArgs, client: client)
        case "vm-pty-attach":
            try runVMPtyAttach(commandArgs: commandArgs, client: client)
        case "vm-ssh-attach":
            // Hidden compatibility alias for workspaces created before the split helper was
            // nested under `cmux vm`.
            try runVMSSHAttach(commandArgs: commandArgs, client: client)

        case "new-workspace":
            Self.warnLegacyVerbDeprecated("new-workspace", replacement: "cmux workspace create")
            try runWorkspaceCreateCommand(
                commandName: "new-workspace",
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId,
                honorJSONOutput: false
            )

        case "close-workspace":
            Self.warnLegacyVerbDeprecated("close-workspace", replacement: "cmux workspace close")
            try runWorkspaceCloseCommand(
                commandName: "close-workspace",
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId,
                requireWorkspaceFlag: true
            )

        case "select-workspace":
            Self.warnLegacyVerbDeprecated("select-workspace", replacement: "cmux workspace select")
            try runWorkspaceSelectCommand(
                commandName: "select-workspace",
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId,
                requireWorkspaceFlag: true
            )

        case "rename-workspace", "rename-window":
            if command == "rename-workspace" {
                Self.warnLegacyVerbDeprecated("rename-workspace", replacement: "cmux workspace rename")
            }
            try runWorkspaceRenameCommand(
                commandName: command,
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId,
                mode: .legacy
            )

        case "current-workspace":
            var params: [String: Any] = [:]
            try applyWindowOrCallerContext(to: &params, client: client, windowRaw: windowFromArgsOrOverride(commandArgs, windowOverride: windowId))
            let response = try client.sendV2(method: "workspace.current", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(response, mode: idFormat)))
            } else {
                let handle = formatHandle(response, kind: "workspace", idFormat: idFormat)
                    ?? (response["workspace_id"] as? String)
                    ?? ""
                print(handle)
            }
        default:
            return false
        }
        return true
    }
}
