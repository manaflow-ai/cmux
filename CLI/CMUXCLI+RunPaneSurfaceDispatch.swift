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


// MARK: - Pane and surface command dispatch
extension CMUXCLI {
    /// Handles pane, split, surface, and terminal text/key socket commands.
    /// Returns true when the command matched; false to let the next dispatcher try.
    func runPaneSurfaceCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowId: String?
    ) throws -> Bool {
        switch command {
        case "new-split":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let (sfArg, rem2) = parseOption(rem1, name: "--surface")
            let (focusOpt, rem3) = parseOption(rem2, name: "--focus")
            let (windowOpt, rem4) = parseOption(rem3, name: "--window")
            let windowRaw = windowOpt ?? windowId
            let workspaceArg = wsArg ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceRaw = sfArg ?? panelArg ?? (wsArg == nil && windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            let direction = try validatedSplitDirection(rem4.first, commandName: "new-split")
            if let unknown = rem4.dropFirst().first(where: { $0.hasPrefix("--") }) {
                throw CLIError(message: "new-split: unknown flag '\(unknown)'")
            }
            var params: [String: Any] = ["direction": direction]
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let sfId { params["surface_id"] = sfId }
            try applyFocusOption(focusOpt, defaultValue: false, to: &params)
            let payload = try client.sendV2(method: "surface.split", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "list-panes":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowId), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "pane.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let panes = payload["panes"] as? [[String: Any]] ?? []
                if panes.isEmpty {
                    print("No panes")
                } else {
                    for pane in panes {
                        let focused = (pane["focused"] as? Bool) == true
                        let handle = textHandle(pane, idFormat: idFormat)
                        let count = pane["surface_count"] as? Int ?? 0
                        let prefix = focused ? "* " : "  "
                        let focusTag = focused ? "  [focused]" : ""
                        print("\(prefix)\(handle)  [\(count) surface\(count == 1 ? "" : "s")]\(focusTag)")
                    }
                }
            }

        case "list-pane-surfaces":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let paneRaw = optionValue(commandArgs, name: "--pane")
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowId), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.surfaces", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces in pane")
                } else {
                    for surface in surfaces {
                        let selected = (surface["selected"] as? Bool) == true
                        let handle = textHandle(surface, idFormat: idFormat)
                        let title = (surface["title"] as? String) ?? ""
                        let prefix = selected ? "* " : "  "
                        let selTag = selected ? "  [selected]" : ""
                        print("\(prefix)\(handle)  \(title)\(selTag)")
                    }
                }
            }

        case "tree":
            try runTreeCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "top":
            try runTopCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "memory":
            try runMemoryCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "focus-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            guard let paneRaw = optionValue(commandArgs, name: "--pane") ?? commandArgs.first else {
                throw CLIError(message: "focus-pane requires --pane <id|ref>")
            }
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowId), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.focus", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane", "workspace"]))

        case "new-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let type = optionValue(commandArgs, name: "--type")
            let direction = optionValue(commandArgs, name: "--direction") ?? "right"
            let url = optionValue(commandArgs, name: "--url")
            let focusOpt = optionValue(commandArgs, name: "--focus")
            var params: [String: Any] = ["direction": direction]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowId), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            if let type { params["type"] = type }
            if let url { params["url"] = url }
            try applyFocusOption(focusOpt, defaultValue: false, to: &params)
            let payload = try client.sendV2(method: "pane.create", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["surface", "pane", "workspace"]))

        case "new-surface":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let type = optionValue(commandArgs, name: "--type")
            let paneRaw = optionValue(commandArgs, name: "--pane")
            let url = optionValue(commandArgs, name: "--url")
            let provider = optionValue(commandArgs, name: "--provider") ?? optionValue(commandArgs, name: "--provider-id")
            let renderer = optionValue(commandArgs, name: "--renderer") ?? optionValue(commandArgs, name: "--renderer-kind")
            let workingDirectory = optionValue(commandArgs, name: "--working-directory") ?? optionValue(commandArgs, name: "--cwd")
            let focusOpt = optionValue(commandArgs, name: "--focus")
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowId), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let paneId { params["pane_id"] = paneId }
            if let type { params["type"] = type }
            if let url { params["url"] = url }
            if let provider { params["provider_id"] = provider }
            if let renderer { params["renderer_kind"] = renderer }
            if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workingDirectory.isEmpty {
                params["working_directory"] = resolvePath(workingDirectory)
            }
            try applyFocusOption(focusOpt, defaultValue: false, to: &params)
            let payload = try client.sendV2(method: "surface.create", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["surface", "pane", "workspace"]))

        case "surface":
            try runSurfaceCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "surface-resume":
            try runSurfaceResumeCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "close-surface":
            let csWsFlag = optionValue(commandArgs, name: "--workspace")
            let windowRaw = windowFromArgsOrOverride(commandArgs, windowOverride: windowId)
            let workspaceArg = csWsFlag ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? optionValue(commandArgs, name: "--panel") ?? (csWsFlag == nil && windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.close", params: params)
            if let closedWorkspaceId = (payload["workspace_id"] as? String) ?? wsId,
               let closedSurfaceId = (payload["surface_id"] as? String) ?? sfId {
                try? tmuxPruneCompatSurfaceState(
                    workspaceId: closedWorkspaceId,
                    surfaceId: closedSurfaceId,
                    client: client
                )
            }
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "drag-surface-to-split":
            try runSplitOff(commandName: "drag-surface-to-split", commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "refresh-surfaces":
            let response = try sendV1Command("refresh_surfaces", client: client)
            print(response)
        case "reload-config":
            if let unexpected = commandArgs.first {
                throw CLIError(message: "reload-config does not accept arguments. Unexpected argument '\(unexpected)'")
            }
            let response = try sendV1Command("reload_config", client: client)
            print(response)

        case "surface-health":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowId), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "surface.health", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces")
                } else {
                    for surface in surfaces {
                        let handle = textHandle(surface, idFormat: idFormat)
                        let sType = (surface["type"] as? String) ?? ""
                        let inWindow = surface["in_window"]
                        let inWindowStr: String
                        if let b = inWindow as? Bool {
                            inWindowStr = " in_window=\(b)"
                        } else {
                            inWindowStr = ""
                        }
                        print("\(handle)  type=\(sType)\(inWindowStr)")
                    }
                }
            }

        case "debug-terminals":
            let unexpected = commandArgs.filter { $0 != "--" }
            if let extra = unexpected.first {
                throw CLIError(message: "debug-terminals: unexpected argument '\(extra)'")
            }
            let payload = try client.sendV2(method: "debug.terminals")
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print(formatDebugTerminalsPayload(payload, idFormat: idFormat))
            }

        case "trigger-flash":
            let tfWsFlag = optionValue(commandArgs, name: "--workspace")
            let explicitWorkspaceArg = tfWsFlag
            let windowRaw = windowFromArgsOrOverride(commandArgs, windowOverride: windowId)
            let preferTTYFallback = windowRaw == nil && ProcessInfo.processInfo.environment["TMUX"] != nil
            let callerWorkspaceArg = preferTTYFallback
                ? nil
                : (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let workspaceArg = explicitWorkspaceArg ?? callerWorkspaceArg
            let explicitSurfaceArg = optionValue(commandArgs, name: "--surface") ?? optionValue(commandArgs, name: "--panel")
            let callerSurfaceArg = explicitSurfaceArg == nil && preferTTYFallback == false && windowRaw == nil
                ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
                : nil
            let surfaceArg = explicitSurfaceArg ?? callerSurfaceArg
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try {
                if explicitWorkspaceArg != nil || winId != nil {
                    return try normalizeWorkspaceHandle(
                        workspaceArg,
                        client: client,
                        windowHandle: winId,
                        allowCurrent: winId != nil
                    )
                }
                return try resolveWorkspaceIdAllowingFallback(workspaceArg, client: client)
            }()
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try {
                if explicitSurfaceArg != nil {
                    return try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId)
                }
                guard let wsId else { return nil }
                return try resolveSurfaceIdAllowingFallback(
                    surfaceArg,
                    workspaceId: wsId,
                    client: client
                )
            }()
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.trigger_flash", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "list-panels":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowId), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "surface.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces")
                } else {
                    for surface in surfaces {
                        let focused = (surface["focused"] as? Bool) == true
                        let handle = textHandle(surface, idFormat: idFormat)
                        let sType = (surface["type"] as? String) ?? ""
                        let title = (surface["title"] as? String) ?? ""
                        let prefix = focused ? "* " : "  "
                        let focusTag = focused ? "  [focused]" : ""
                        let titlePart = title.isEmpty ? "" : "  \"\(title)\""
                        print("\(prefix)\(handle)  \(sType)\(focusTag)\(titlePart)")
                    }
                }
            }

        case "focus-panel":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            guard let panelRaw = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "focus-panel requires --panel")
            }
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowId), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelRaw, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.focus", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "read-screen":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let (windowOpt, rem2) = parseOption(rem1, name: "--window")
            let (linesArg, rem3) = parseOption(rem2, name: "--lines")
            let trailing = rem3.filter { $0 != "--scrollback" }
            if !trailing.isEmpty {
                throw CLIError(message: "read-screen: unexpected arguments: \(trailing.joined(separator: " "))")
            }

            let windowRaw = windowOpt ?? windowId
            let workspaceArg = wsArg ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)

            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let sfId { params["surface_id"] = sfId }

            let includeScrollback = rem3.contains("--scrollback")
            if includeScrollback {
                params["scrollback"] = true
            }
            if let linesArg {
                guard let lineCount = Int(linesArg), lineCount > 0 else {
                    throw CLIError(message: "--lines must be greater than 0")
                }
                params["lines"] = lineCount
                params["scrollback"] = true
            }

            let payload = try client.sendV2(method: "surface.read_text", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print((payload["text"] as? String) ?? "")
            }

        case "send":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let (windowOpt, rem2) = parseOption(rem1, name: "--window")
            let windowRaw = windowOpt ?? windowId
            let workspaceArg = wsArg ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            let rawText = rem2.dropFirst(rem2.first == "--" ? 1 : 0).joined(separator: " ")
            guard !rawText.isEmpty else { throw CLIError(message: "send requires text") }
            let text = unescapeSendText(rawText)
            var params: [String: Any] = ["text": text]
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-key":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let (windowOpt, rem2) = parseOption(rem1, name: "--window")
            let windowRaw = windowOpt ?? windowId
            let workspaceArg = wsArg ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            let keyArgs = rem2.first == "--" ? Array(rem2.dropFirst()) : rem2
            guard let key = keyArgs.first else { throw CLIError(message: "send-key requires a key") }
            var params: [String: Any] = ["key": key]
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_key", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-panel":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let (windowOpt, rem2) = parseOption(rem1, name: "--window")
            let windowRaw = windowOpt ?? windowId
            let workspaceArg = wsArg ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            guard let panelArg else {
                throw CLIError(message: "send-panel requires --panel")
            }
            let rawText = rem2.dropFirst(rem2.first == "--" ? 1 : 0).joined(separator: " ")
            guard !rawText.isEmpty else { throw CLIError(message: "send-panel requires text") }
            let text = unescapeSendText(rawText)
            var params: [String: Any] = ["text": text]
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelArg, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-key-panel":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let (windowOpt, rem2) = parseOption(rem1, name: "--window")
            let windowRaw = windowOpt ?? windowId
            let workspaceArg = wsArg ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            guard let panelArg else {
                throw CLIError(message: "send-key-panel requires --panel")
            }
            let skpArgs = rem2.first == "--" ? Array(rem2.dropFirst()) : rem2
            let key = skpArgs.first ?? ""
            guard !key.isEmpty else { throw CLIError(message: "send-key-panel requires a key") }
            var params: [String: Any] = ["key": key]
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelArg, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_key", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))
        default:
            return false
        }
        return true
    }
}
