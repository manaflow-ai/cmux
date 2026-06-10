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


// MARK: - Notification and sidebar command dispatch
extension CMUXCLI {
    /// Handles notification, status/progress/log, and sidebar socket commands.
    /// Returns true when the command matched; false to let the next dispatcher try.
    func runNotificationSidebarCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowId: String?
    ) throws -> Bool {
        switch command {
        case "notify":
            let title = optionValue(commandArgs, name: "--title") ?? "Notification"
            let subtitle = optionValue(commandArgs, name: "--subtitle") ?? ""
            let body = optionValue(commandArgs, name: "--body") ?? ""
            let explicitWorkspaceArg = optionValue(commandArgs, name: "--workspace")
            let windowRaw = windowFromArgsOrOverride(commandArgs, windowOverride: windowId)
            let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
            let preferTTYFallback = windowRaw == nil && ProcessInfo.processInfo.environment["TMUX"] != nil
            let explicitSurfaceArg = optionValue(commandArgs, name: "--surface"), env = ProcessInfo.processInfo.environment
            let hasExplicitHandle = [explicitWorkspaceArg, explicitSurfaceArg].compactMap { $0 }.contains { !isUUID($0) }
            if hasExplicitHandle && explicitSurfaceArg != nil {
                let targetWorkspace: String
                let targetSurface: String
                if let windowHandle, explicitWorkspaceArg == nil, let explicitSurfaceArg {
                    let target = try resolveSurfaceTargetInWindow(
                        explicitSurfaceArg,
                        windowHandle: windowHandle,
                        client: client
                    )
                    targetWorkspace = target.workspaceId
                    targetSurface = target.surfaceId
                } else {
                    let workspaceRaw = explicitWorkspaceArg
                        ?? (windowRaw == nil ? env["CMUX_WORKSPACE_ID"] : nil)
                    targetWorkspace = try (explicitWorkspaceArg == nil
                        ? resolveWorkspaceIdAllowingFallback(workspaceRaw, client: client)
                        : resolveWorkspaceId(workspaceRaw, client: client, windowHandle: windowHandle))
                    targetSurface = try explicitSurfaceArg.map { try resolveSurfaceId($0, workspaceId: targetWorkspace, client: client) }
                        ?? resolveSurfaceId(nil, workspaceId: targetWorkspace, client: client)
                }
                let payload = notificationPayload(title: title, subtitle: subtitle, body: body)
                let response = try sendV1Command("notify_target \(targetWorkspace) \(targetSurface) \(payload)", client: client)
                print(response)
                return true
            }
            var params: [String: Any] = ["title": title, "subtitle": subtitle, "body": body]
            let method: String
            if explicitSurfaceArg != nil {
                method = "notification.create"
                if let windowHandle { params["window_id"] = windowHandle }
                if let explicitWorkspaceArg {
                    params["workspace_id"] = try resolveWorkspaceId(explicitWorkspaceArg, client: client, windowHandle: windowHandle)
                }
                if let explicitSurfaceArg { params["surface_id"] = explicitSurfaceArg }
            } else {
                if let windowHandle {
                    method = "notification.create"
                    params["window_id"] = windowHandle
                    if let explicitWorkspaceArg {
                        params["workspace_id"] = try resolveWorkspaceId(explicitWorkspaceArg, client: client, windowHandle: windowHandle)
                    } else {
                        params["workspace_id"] = try requireCurrentWorkspaceId(
                            windowHandle: windowHandle,
                            client: client,
                            command: "notify"
                        )
                    }
                } else {
                    method = "notification.create_for_caller"
                    params["prefer_tty"] = preferTTYFallback && explicitWorkspaceArg == nil
                    let workspaceArg = explicitWorkspaceArg ?? (windowRaw == nil ? env["CMUX_WORKSPACE_ID"] : nil)
                    if let workspaceArg, isUUID(workspaceArg) || explicitWorkspaceArg != nil {
                        params["preferred_workspace_id"] = isUUID(workspaceArg) ? workspaceArg : try resolveWorkspaceId(workspaceArg, client: client)
                    }
                    if windowRaw == nil, let surfaceId = env["CMUX_SURFACE_ID"], isUUID(surfaceId) { params["preferred_surface_id"] = surfaceId }
                    if let callerTTY = resolveCallerTTYName() { params["caller_tty"] = callerTTY }
                }
            }
            let payload = try client.sendV2(method: method, params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")
        case "list-notifications":
            let response = try sendV1Command("list_notifications", client: client)
            if jsonOutput {
                let notifications = parseNotifications(response)
                let payload = notifications.map { item in
                    var dict: [String: Any] = [
                        "id": item.id,
                        "workspace_id": item.workspaceId,
                        "is_read": item.isRead,
                        "title": item.title,
                        "subtitle": item.subtitle,
                        "body": item.body
                    ]
                    dict["surface_id"] = item.surfaceId ?? NSNull()
                    dict["created_at"] = item.createdAt ?? NSNull()
                    dict["tab_title"] = item.tabTitle ?? NSNull()
                    return dict
                }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "dismiss-notification":
            let id = optionValue(commandArgs, name: "--id")
            let allRead = hasFlag(commandArgs, name: "--all-read")
            let okText = String(localized: "common.ok", defaultValue: "OK")
            guard (id != nil) != allRead else {
                throw CLIError(message: String(localized: "cli.error.dismissNotificationSelector", defaultValue: "dismiss-notification requires exactly one of --id or --all-read"))
            }
            if let id {
                let payload = try client.sendV2(method: "notification.dismiss", params: ["id": id])
                printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: okText)
            } else {
                let payload = try client.sendV2(method: "notification.dismiss", params: ["all_read": true])
                printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: okText)
            }

        case "mark-notification-read":
            let id = optionValue(commandArgs, name: "--id")
            let workspaceArg = optionValue(commandArgs, name: "--workspace")
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let windowHandle = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowId), client: client)
            let all = hasFlag(commandArgs, name: "--all")
            let okText = String(localized: "common.ok", defaultValue: "OK")
            let selectorCount = (id == nil ? 0 : 1) + (workspaceArg == nil ? 0 : 1) + (all ? 1 : 0)
            guard selectorCount == 1 else {
                throw CLIError(message: String(localized: "cli.error.markNotificationReadSelector", defaultValue: "mark-notification-read requires exactly one selector: --id, --workspace, or --all"))
            }
            if surfaceArg != nil, workspaceArg == nil {
                throw CLIError(message: String(localized: "cli.error.markNotificationReadSurfaceRequiresWorkspace", defaultValue: "--surface requires --workspace"))
            }

            var params: [String: Any] = [:]
            if let id {
                params["id"] = id
            } else if let workspaceArg {
                let workspaceId = try resolveWorkspaceId(workspaceArg, client: client, windowHandle: windowHandle)
                params["tab_id"] = workspaceId
                if let surfaceArg {
                    params["surface_id"] = try resolveSurfaceId(surfaceArg, workspaceId: workspaceId, client: client)
                }
            } else if all {
                params["all"] = true
            }
            let payload = try client.sendV2(method: "notification.mark_read", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: okText)

        case "open-notification":
            guard let id = optionValue(commandArgs, name: "--id") else {
                throw CLIError(message: String(localized: "cli.error.openNotificationRequiresId", defaultValue: "open-notification requires --id"))
            }
            let payload = try client.sendV2(method: "notification.open", params: ["id": id])
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "jump-to-unread":
            let payload = try client.sendV2(method: "notification.jump_to_unread")
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "clear-notifications":
            var socketCmd = "clear_notifications"
            let windowRaw = windowFromArgsOrOverride(commandArgs, windowOverride: windowId)
            let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
            if let wsFlag = optionValue(commandArgs, name: "--workspace") {
                let wsId = try resolveWorkspaceId(wsFlag, client: client, windowHandle: windowHandle)
                socketCmd += " --tab=\(wsId)"
            } else if let windowHandle {
                let wsId = try requireCurrentWorkspaceId(
                    windowHandle: windowHandle,
                    client: client,
                    command: "clear-notifications"
                )
                socketCmd += " --tab=\(wsId)"
            } else if windowRaw == nil,
                      let envWs = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"],
                      let wsId = try? resolveWorkspaceId(envWs, client: client) {
                socketCmd += " --tab=\(wsId)"
            }
            let response = try sendV1Command(socketCmd, client: client)
            print(response)

        case "set-status":
            let response = try forwardSidebarMetadataCommand(
                "set_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-status":
            let response = try forwardSidebarMetadataCommand(
                "clear_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "list-status":
            let response = try forwardSidebarMetadataCommand(
                "list_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "set-progress":
            let response = try forwardSidebarMetadataCommand(
                "set_progress",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-progress":
            let response = try forwardSidebarMetadataCommand(
                "clear_progress",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "log":
            let response = try forwardSidebarMetadataCommand(
                "log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-log":
            let response = try forwardSidebarMetadataCommand(
                "clear_log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "list-log":
            let response = try forwardSidebarMetadataCommand(
                "list_log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "sidebar-state":
            let response = try forwardSidebarMetadataCommand(
                "sidebar_state",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "right-sidebar":
            try forwardRightSidebarCommand(
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )

        case "sidebar":
            try runSidebarCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput
            )
        default:
            return false
        }
        return true
    }
}
