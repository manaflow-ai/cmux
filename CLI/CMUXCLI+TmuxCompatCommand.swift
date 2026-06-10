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


// MARK: - tmux compat command dispatch
extension CMUXCLI {
    func runTmuxCompatCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        switch command {
        case "capture-pane":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let (windowOpt, rem2) = parseOption(rem1, name: "--window")
            let (linesArg, rem3) = parseOption(rem2, name: "--lines")
            let windowRaw = windowOpt ?? windowOverride
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

        case "resize-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let paneArg = optionValue(commandArgs, name: "--pane")
            let amountArg = optionValue(commandArgs, name: "--amount")
            let amount = Int(amountArg ?? "1") ?? 1
            if amount <= 0 {
                throw CLIError(message: "--amount must be greater than 0")
            }

            let direction: String = {
                if commandArgs.contains("-L") { return "left" }
                if commandArgs.contains("-R") { return "right" }
                if commandArgs.contains("-U") { return "up" }
                if commandArgs.contains("-D") { return "down" }
                return "right"
            }()

            var params: [String: Any] = ["direction": direction, "amount": amount]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneArg, client: client, workspaceHandle: wsId, windowHandle: winId, allowFocused: true)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.resize", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane"]))

        case "pipe-pane":
            let (workspaceOpt, pipeRem0) = parseOption(commandArgs, name: "--workspace")
            let (surfaceArg, pipeRem1) = parseOption(pipeRem0, name: "--surface")
            let (windowOpt, pipeRem2) = parseOption(pipeRem1, name: "--window")
            let (cmdOpt, pipeRem3) = parseOption(pipeRem2, name: "--command")
            let effectiveWindowRaw = windowOpt ?? windowOverride
            let workspaceArg = workspaceOpt ?? (effectiveWindowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let commandText: String = {
                if let cmdOpt { return cmdOpt }
                let trimmed = pipeRem3.dropFirst(pipeRem3.first == "--" ? 1 : 0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed
            }()
            guard !commandText.isEmpty else {
                throw CLIError(message: "pipe-pane requires --command <shell-command>")
            }

            var params: [String: Any] = ["scrollback": true]
            let winId = try normalizeWindowHandle(effectiveWindowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId, allowCurrent: winId == nil)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.read_text", params: params)
            let text = (payload["text"] as? String) ?? ""
            let shell = try runShellCommand(commandText, stdinText: text)
            if shell.status != 0 {
                throw CLIError(message: "pipe-pane command failed (\(shell.status)): \(shell.stderr)")
            }
            if jsonOutput {
                print(jsonString([
                    "ok": true,
                    "status": shell.status,
                    "stdout": shell.stdout,
                    "stderr": shell.stderr
                ]))
            } else {
                if !shell.stdout.isEmpty {
                    print(shell.stdout, terminator: "")
                }
                print("OK")
            }

        case "wait-for":
            let signal = commandArgs.contains("-S") || commandArgs.contains("--signal")
            let timeoutRaw = optionValue(commandArgs, name: "--timeout")
            let timeout = timeoutRaw.flatMap { Double($0) } ?? 30.0
            let name = commandArgs.first(where: { !$0.hasPrefix("-") }) ?? ""
            guard !name.isEmpty else {
                throw CLIError(message: "wait-for requires a name")
            }
            let signalURL = tmuxWaitForSignalURL(name: name)
            if signal {
                FileManager.default.createFile(atPath: signalURL.path, contents: Data())
                print("OK")
                return
            }
            let deadline = Date().addingTimeInterval(timeout)
            do {
                try SocketClient.waitForFilesystemPath(signalURL.path, timeout: max(0, deadline.timeIntervalSinceNow))
                try? FileManager.default.removeItem(at: signalURL)
                print("OK")
                return
            } catch {
                if FileManager.default.fileExists(atPath: signalURL.path) {
                    try? FileManager.default.removeItem(at: signalURL)
                    print("OK")
                    return
                }
            }
            throw CLIError(message: "wait-for timed out waiting for '\(name)'")

        case "swap-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            guard let sourcePaneRaw = optionValue(commandArgs, name: "--pane") else {
                throw CLIError(message: "swap-pane requires --pane")
            }
            guard let targetPaneRaw = optionValue(commandArgs, name: "--target-pane") else {
                throw CLIError(message: "swap-pane requires --target-pane")
            }
            let focusRaw = optionValue(commandArgs, name: "--focus")
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sourcePane = try normalizePaneHandle(sourcePaneRaw, client: client, workspaceHandle: wsId, windowHandle: winId)
            let targetPane = try normalizePaneHandle(targetPaneRaw, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let sourcePane { params["pane_id"] = sourcePane }
            if let targetPane { params["target_pane_id"] = targetPane }
            try applyFocusOption(focusRaw, defaultValue: false, to: &params)
            let payload = try client.sendV2(method: "pane.swap", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "break-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let paneArg = optionValue(commandArgs, name: "--pane")
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let focusRaw = optionValue(commandArgs, name: "--focus")
            try rejectConflictingFocusFlags(commandArgs)
            var params: [String: Any] = [:]
            try applyFocusOption(focusRaw, defaultValue: false, to: &params)
            if commandArgs.contains("--no-focus") {
                params["focus"] = false
            }
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneArg, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let paneId { params["pane_id"] = paneId }
            let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let surfaceId { params["surface_id"] = surfaceId }
            let payload = try client.sendV2(method: "pane.break", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "join-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let sourcePaneArg = optionValue(commandArgs, name: "--pane")
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            guard let targetPaneArg = optionValue(commandArgs, name: "--target-pane") else {
                throw CLIError(message: "join-pane requires --target-pane")
            }
            let focusRaw = optionValue(commandArgs, name: "--focus")
            try rejectConflictingFocusFlags(commandArgs)
            var params: [String: Any] = [:]
            try applyFocusOption(focusRaw, defaultValue: false, to: &params)
            if commandArgs.contains("--no-focus") {
                params["focus"] = false
            }
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sourcePaneId = try normalizePaneHandle(sourcePaneArg, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let sourcePaneId { params["pane_id"] = sourcePaneId }
            let targetPaneId = try normalizePaneHandle(targetPaneArg, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let targetPaneId { params["target_pane_id"] = targetPaneId }
            let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId)
            if let surfaceId { params["surface_id"] = surfaceId }
            let payload = try client.sendV2(method: "pane.join", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "last-window":
            var params: [String: Any] = [:]
            if let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client) {
                params["window_id"] = winId
            }
            let payload = try client.sendV2(method: "workspace.last", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "next-window":
            var params: [String: Any] = [:]
            if let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client) {
                params["window_id"] = winId
            }
            let payload = try client.sendV2(method: "workspace.next", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "previous-window":
            var params: [String: Any] = [:]
            if let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client) {
                params["window_id"] = winId
            }
            let payload = try client.sendV2(method: "workspace.previous", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "last-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "pane.last", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane"]))

        case "find-window":
            let includeContent = commandArgs.contains("--content")
            let shouldSelect = commandArgs.contains("--select")
            let (windowOpt, queryArgs) = parseOption(commandArgs, name: "--window")
            let query = queryArgs
                .filter { !$0.hasPrefix("-") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var listParams: [String: Any] = [:]
            if let winId = try normalizeWindowHandle(windowOpt ?? windowOverride, client: client) {
                listParams["window_id"] = winId
            }
            let listPayload = try client.sendV2(method: "workspace.list", params: listParams)
            let workspaces = listPayload["workspaces"] as? [[String: Any]] ?? []

            var matches: [[String: Any]] = []
            for ws in workspaces {
                let title = (ws["title"] as? String) ?? ""
                let titleMatch = query.isEmpty || title.localizedCaseInsensitiveContains(query)
                var contentMatch = false
                if includeContent && !query.isEmpty, let wsId = ws["id"] as? String {
                    let textPayload = try? client.sendV2(method: "surface.read_text", params: ["workspace_id": wsId])
                    let text = (textPayload?["text"] as? String) ?? ""
                    contentMatch = text.localizedCaseInsensitiveContains(query)
                }
                if titleMatch || contentMatch {
                    matches.append(ws)
                }
            }

            if shouldSelect, let first = matches.first, let wsId = first["id"] as? String {
                var selectParams: [String: Any] = ["workspace_id": wsId]
                if let windowId = listParams["window_id"] {
                    selectParams["window_id"] = windowId
                }
                _ = try client.sendV2(method: "workspace.select", params: selectParams)
            }

            if jsonOutput {
                let formatted = formatIDs(["matches": matches], mode: idFormat) as? [String: Any]
                print(jsonString(["matches": formatted?["matches"] ?? []]))
            } else if matches.isEmpty {
                print("No matches")
            } else {
                for item in matches {
                    let handle = textHandle(item, idFormat: idFormat)
                    let title = (item["title"] as? String) ?? ""
                    print("\(handle)  \"\(title)\"")
                }
            }

        case "clear-history":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            var params: [String: Any] = [:]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.clear_history", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "set-hook":
            var store = loadTmuxCompatStore()
            if commandArgs.contains("--list") {
                if jsonOutput {
                    print(jsonString(["hooks": store.hooks]))
                } else if store.hooks.isEmpty {
                    print("No hooks configured")
                } else {
                    for (event, hookCmd) in store.hooks.sorted(by: { $0.key < $1.key }) {
                        print("\(event) -> \(hookCmd)")
                    }
                }
                return
            }
            if commandArgs.contains("--unset") {
                guard let event = commandArgs.last else {
                    throw CLIError(message: "set-hook --unset requires an event name")
                }
                store.hooks.removeValue(forKey: event)
                try saveTmuxCompatStore(store)
                print("OK")
                return
            }
            guard let event = commandArgs.first(where: { !$0.hasPrefix("-") }) else {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
            let commandText = commandArgs.drop(while: { $0 != event }).dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commandText.isEmpty else {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
            store.hooks[event] = commandText
            try saveTmuxCompatStore(store)
            print("OK")

        case "popup":
            throw CLIError(message: "popup is not supported yet in cmux CLI parity mode")

        case "bind-key", "unbind-key", "copy-mode":
            throw CLIError(message: "\(command) is not supported yet in cmux CLI parity mode")

        case "set-buffer":
            let (nameArg, rem0) = parseOption(commandArgs, name: "--name")
            let name = (nameArg?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? nameArg! : "default"
            let content = rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError(message: "set-buffer requires text")
            }
            var store = loadTmuxCompatStore()
            store.buffers[name] = content
            try saveTmuxCompatStore(store)
            print("OK")

        case "list-buffers":
            let store = loadTmuxCompatStore()
            if jsonOutput {
                let payload = store.buffers.map { key, value in ["name": key, "size": value.count] }
                print(jsonString(["buffers": payload.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]))
            } else if store.buffers.isEmpty {
                print("No buffers")
            } else {
                for key in store.buffers.keys.sorted() {
                    let size = store.buffers[key]?.count ?? 0
                    print("\(key)\t\(size)")
                }
            }

        case "paste-buffer":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let name = optionValue(commandArgs, name: "--name") ?? "default"
            let store = loadTmuxCompatStore()
            guard let buffer = store.buffers[name] else {
                throw CLIError(message: "Buffer not found: \(name)")
            }
            var params: [String: Any] = ["text": buffer]
            let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
            if let winId { params["window_id"] = winId }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId, allowCurrent: winId == nil)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "respawn-pane":
            let (workspaceOpt, respawnRem0) = parseOption(commandArgs, name: "--workspace")
            let (surfaceArg, respawnRem1) = parseOption(respawnRem0, name: "--surface")
            let (windowOpt, respawnRem2) = parseOption(respawnRem1, name: "--window")
            let (commandOpt, respawnRem3) = parseOption(respawnRem2, name: "--command")
            let effectiveWindowRaw = windowOpt ?? windowOverride
            let workspaceArg = workspaceOpt ?? (effectiveWindowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let commandText = (commandOpt ?? respawnRem3.dropFirst(respawnRem3.first == "--" ? 1 : 0).joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            let finalCommand = commandText.isEmpty ? "exec ${SHELL:-/bin/zsh} -l" : commandText
            var params: [String: Any] = [
                "command": finalCommand,
                "tmux_start_command": finalCommand
            ]
            let winId = try normalizeWindowHandle(effectiveWindowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let wsHandle = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId, allowCurrent: winId == nil)
            let wsId = try wsHandle.map { try resolveWorkspaceId($0, client: client, windowHandle: winId) }
            if let wsId { params["workspace_id"] = wsId }
            let sfHandle = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId, allowFocused: true)
            if let sfHandle {
                if let wsId {
                    params["surface_id"] = try resolveSurfaceId(sfHandle, workspaceId: wsId, client: client)
                } else {
                    params["surface_id"] = sfHandle
                }
            }
            let payload = try client.sendV2(method: "surface.respawn", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "display-message":
            let printOnly = commandArgs.contains("-p") || commandArgs.contains("--print")
            let message = commandArgs
                .filter { !$0.hasPrefix("-") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw CLIError(message: "display-message requires text")
            }
            if printOnly {
                print(message)
                return
            }
            let payload = try client.sendV2(method: "notification.create", params: ["title": "cmux", "body": message])
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print(message)
            }

        default:
            throw CLIError(message: "Unsupported tmux compatibility command: \(command)")
        }
    }

}
