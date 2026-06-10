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


// MARK: - Workspace and tab commands
extension CMUXCLI {
    func runReorderWorkspace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let workspaceRaw = optionValue(commandArgs, name: "--workspace") ?? commandArgs.first
        guard let workspaceRaw else {
            throw CLIError(message: "reorder-workspace requires --workspace <id|ref|index>")
        }

        let windowRaw = optionValue(commandArgs, name: "--window")
        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)

        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-workspace")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-workspace")
        let beforeHandle = try normalizeWorkspaceHandle(beforeRaw, client: client, windowHandle: windowHandle)
        let afterHandle = try normalizeWorkspaceHandle(afterRaw, client: client, windowHandle: windowHandle)

        var params: [String: Any] = [:]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let beforeHandle { params["before_workspace_id"] = beforeHandle }
        if let afterHandle { params["after_workspace_id"] = afterHandle }
        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        let dryRun = hasFlag(commandArgs, name: "--dry-run")
        if dryRun {
            params["dry_run"] = true
        }

        let payload = try client.sendV2(method: "workspace.reorder", params: params)
        let summary = dryRun
            ? reorderResultLines(payload, idFormat: idFormat, dryRun: true).joined(separator: "\n")
            : "OK workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown") index=\(payload["index"] ?? "?")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    func runReorderWorkspaces(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard let orderRaw = optionValue(commandArgs, name: "--order") else {
            throw CLIError(message: String(
                localized: "cli.reorderWorkspaces.error.missingOrder",
                defaultValue: "reorder-workspaces requires --order <id|ref|index>,<id|ref|index>,..."
            ))
        }

        let rawRefs = orderRaw
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !rawRefs.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.reorderWorkspaces.error.emptyOrder",
                defaultValue: "reorder-workspaces requires at least one workspace in --order"
            ))
        }
        guard !rawRefs.contains(where: \.isEmpty) else {
            throw CLIError(message: String(
                localized: "cli.reorderWorkspaces.error.emptyOrderItem",
                defaultValue: "reorder-workspaces --order cannot contain empty workspace refs"
            ))
        }

        let windowRaw = optionValue(commandArgs, name: "--window")
        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandles = try rawRefs.map { rawRef in
            guard let workspaceHandle = try normalizeWorkspaceHandle(rawRef, client: client, windowHandle: windowHandle) else {
                let messageFormat = String(
                    localized: "cli.reorderWorkspaces.error.workspaceNotFound",
                    defaultValue: "Workspace not found: %@"
                )
                throw CLIError(message: String(format: messageFormat, rawRef))
            }
            return workspaceHandle
        }

        var params: [String: Any] = ["workspace_ids": workspaceHandles]
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        let dryRun = hasFlag(commandArgs, name: "--dry-run")
        if dryRun {
            params["dry_run"] = true
        }

        let payload = try client.sendV2(method: "workspace.reorder_many", params: params)
        let summary = reorderResultLines(payload, idFormat: idFormat, dryRun: dryRun).joined(separator: "\n")
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func reorderResultLines(
        _ payload: [String: Any],
        idFormat: CLIIDFormat,
        dryRun: Bool
    ) -> [String] {
        let planItems = payload["plan"] as? [[String: Any]] ?? [payload]
        let lineFormat = dryRun
            ? String(
                localized: "cli.reorderWorkspaces.result.planLine",
                defaultValue: "OK plan workspace=%@ window=%@ index=%@"
            )
            : String(
                localized: "cli.reorderWorkspaces.result.appliedLine",
                defaultValue: "OK workspace=%@ window=%@ index=%@"
            )
        return planItems.map { item in
            let workspace = formatHandle(item, kind: "workspace", idFormat: idFormat) ?? "unknown"
            let window = formatHandle(item, kind: "window", idFormat: idFormat) ?? "unknown"
            let index = item["to_index"] ?? item["index"] ?? "?"
            return String(format: lineFormat, workspace, window, String(describing: index))
        }
    }

    func runSimulateSidebarDrag(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let windowRaw = optionValue(commandArgs, name: "--window")
        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        guard let windowHandle else {
            throw CLIError(message: "simulate-sidebar-drag requires --window <id|ref|index>")
        }
        guard let fromRaw = optionValue(commandArgs, name: "--from") else {
            throw CLIError(message: "simulate-sidebar-drag requires --from <workspace id|ref|index>")
        }
        guard let toRaw = optionValue(commandArgs, name: "--to") else {
            throw CLIError(message: "simulate-sidebar-drag requires --to <workspace id|ref|index>")
        }
        let fromHandle = try normalizeWorkspaceHandle(fromRaw, client: client, windowHandle: windowHandle)
        let toHandle = try normalizeWorkspaceHandle(toRaw, client: client, windowHandle: windowHandle)
        guard let fromHandle, let toHandle else {
            throw CLIError(message: "simulate-sidebar-drag could not resolve --from / --to to workspace ids")
        }

        var params: [String: Any] = [
            "window_id": windowHandle,
            "from_tab_id": fromHandle,
            "to_tab_id": toHandle
        ]
        var requestedDurationMs = 1000  // matches server default
        var requestedSteps: Int?
        if let durationRaw = optionValue(commandArgs, name: "--duration-ms") {
            guard let duration = Int(durationRaw), duration > 0 else {
                throw CLIError(message: "--duration-ms must be a positive integer")
            }
            params["duration_ms"] = duration
            requestedDurationMs = duration
        }
        if let stepsRaw = optionValue(commandArgs, name: "--steps") {
            guard let steps = Int(stepsRaw), steps > 0 else {
                throw CLIError(message: "--steps must be a positive integer")
            }
            params["steps"] = steps
            requestedSteps = steps
        }

        // The handler blocks until the simulated drag completes
        // (duration_ms in the common path; longer when --steps > path
        // length because the per-step interval has a 1ms minimum). The
        // default 15s socket response timeout would abort long profiling
        // runs while the app keeps simulating. Allow generous slack.
        let stepBasedMinMs = (requestedSteps ?? 0)  // server enforces 1ms min interval
        let expectedRuntimeMs = max(requestedDurationMs, stepBasedMinMs)
        let responseTimeout = max(30.0, Double(expectedRuntimeMs) / 1000.0 + 10.0)

        let payload = try client.sendV2(
            method: "debug.sidebar.simulate_drag",
            params: params,
            responseTimeout: responseTimeout
        )
        let summary = "OK steps=\(payload["steps"] ?? "?") duration_ms=\(payload["duration_ms"] ?? "?") edge=\(payload["edge"] ?? "?")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    func runWorkspaceAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (actionOpt, rem1) = parseOption(rem0, name: "--action")
        let (titleOpt, rem2) = parseOption(rem1, name: "--title")
        let (colorOpt, rem3) = parseOption(rem2, name: "--color")
        let (descriptionOpt, rem4) = parseOption(rem3, name: "--description")
        let (windowOpt, rem5) = parseOption(rem4, name: "--window")

        var positional = rem5
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "workspace-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let windowRaw = windowOpt ?? windowOverride
        let workspaceArg = workspaceOpt ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceId = try normalizeWorkspaceHandle(
            workspaceArg,
            client: client,
            windowHandle: windowHandle,
            allowCurrent: true
        )

        let inferredPositionalRaw = positional.joined(separator: " ")
        let inferredPositional = inferredPositionalRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (action == "rename" && !inferredPositional.isEmpty ? inferredPositional : nil))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action rename requires --title <text> (or a trailing title)")
        }

        let color = (
            colorOpt ?? (action == "set_color" ? (inferredPositional.isEmpty ? nil : inferredPositional) : nil)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "set_color", (color?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action set-color requires --color <name|#hex> (or a trailing color)")
        }

        let description = (
            descriptionOpt ?? (action == "set_description" && !inferredPositional.isEmpty ? inferredPositionalRaw : nil)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "set_description", (description?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action set-description requires --description <text> (or trailing text)")
        }

        var params: [String: Any] = ["action": action]
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }
        if let color, !color.isEmpty {
            params["color"] = color
        }
        if let description, !description.isEmpty {
            params["description"] = description
        }

        let payload = try client.sendV2(method: "workspace.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let windowHandle = formatHandle(payload, kind: "window", idFormat: idFormat) {
            summaryParts.append("window=\(windowHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let index = payload["index"] {
            summaryParts.append("index=\(index)")
        }
        if let color = payload["color"] as? String {
            summaryParts.append("color=\(color)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    func runTabAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (actionOpt, rem3) = parseOption(rem2, name: "--action")
        let (titleOpt, rem4) = parseOption(rem3, name: "--title")
        let (urlOpt, rem5) = parseOption(rem4, name: "--url")
        let (focusOpt, rem6) = parseOption(rem5, name: "--focus")
        let (windowOpt, rem7) = parseOption(rem6, name: "--window")

        var positional = rem7
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "tab-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "tab-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let windowRaw = windowOpt ?? windowOverride
        let workspaceArg = workspaceOpt ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let tabArg = tabOpt
            ?? surfaceOpt
            ?? (workspaceOpt == nil && windowRaw == nil
                ? (ProcessInfo.processInfo.environment["CMUX_TAB_ID"] ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"])
                : nil)

        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceId = try normalizeWorkspaceHandle(
            workspaceArg,
            client: client,
            windowHandle: windowHandle,
            allowCurrent: true
        )
        // If a workspace is explicitly targeted and no tab/surface is provided, let server-side
        // tab.action resolve that workspace's focused tab instead of using global focus.
        let allowFocusedFallback = (workspaceId == nil)
        let surfaceId = try normalizeTabHandle(
            tabArg,
            client: client,
            workspaceHandle: workspaceId,
            windowHandle: windowHandle,
            allowFocused: allowFocusedFallback
        )

        let inferredTitle = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "tab-action rename requires --title <text> (or a trailing title)")
        }

        var params: [String: Any] = ["action": action]
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let surfaceId {
            params["surface_id"] = surfaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }
        if let urlOpt, !urlOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["url"] = urlOpt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try applyTabActionFocusOption(focusOpt, to: &params)
        let payload = try client.sendV2(method: "tab.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let tabHandle = formatTabHandle(payload, idFormat: idFormat) { summaryParts.append("tab=\(tabHandle)") }
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) { summaryParts.append("workspace=\(workspaceHandle)") }
        if let closed = payload["closed"] { summaryParts.append("closed=\(closed)") }
        if let created = formatCreatedTabHandle(payload, idFormat: idFormat) { summaryParts.append("created=\(created)") }
        appendCreatedWorkspaceSummaryParts(from: payload, idFormat: idFormat, to: &summaryParts)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }
    enum WorkspaceRenameCommandMode {
        case legacy
        case namespace
    }

    func runWorkspaceListCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        var params: [String: Any] = [:]
        try applyWindowOrCallerContext(
            to: &params,
            client: client,
            windowRaw: windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride)
        )
        let payload = try client.sendV2(method: "workspace.list", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
            if workspaces.isEmpty {
                print("No workspaces")
            } else {
                for ws in workspaces {
                    let selected = (ws["selected"] as? Bool) == true
                    let handle = textHandle(ws, idFormat: idFormat)
                    let title = (ws["title"] as? String) ?? ""
                    let remoteTag: String = {
                        guard let remote = ws["remote"] as? [String: Any],
                              (remote["enabled"] as? Bool) == true else {
                            return ""
                        }
                        let transport = (remote["transport"] as? String) ?? "remote"
                        let state = (remote["state"] as? String) ?? "unknown"
                        return "  [\(transport):\(state)]"
                    }()
                    let prefix = selected ? "* " : "  "
                    let selTag = selected ? "  [selected]" : ""
                    let titlePart = title.isEmpty ? "" : "  \(title)"
                    print("\(prefix)\(handle)\(titlePart)\(remoteTag)\(selTag)")
                }
            }
        }
    }

    func runWorkspaceCreateCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?,
        honorJSONOutput: Bool
    ) throws {
        let (commandOpt, rem0) = parseOption(commandArgs, name: "--command")
        let (cwdOpt, rem1) = parseOption(rem0, name: "--cwd")
        let (nameOpt, rem2) = parseOption(rem1, name: "--name")
        let (descriptionOpt, rem3) = parseOption(rem2, name: "--description")
        let (layoutOpt, rem4) = parseOption(rem3, name: "--layout")
        let (windowOpt, rem5) = parseOption(rem4, name: "--window")
        let (focusOpt, remaining) = parseOption(rem5, name: "--focus")
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "\(commandName): unknown flag '\(unknown)'. Known flags: --name <title>, --description <text>, --command <text>, --cwd <path>, --layout <json>, --window <id|ref|index>, --focus <true|false>")
        }
        var params: [String: Any] = [:]
        try applyWindowOrCallerContext(to: &params, client: client, windowRaw: windowOpt ?? windowOverride)
        if let cwdOpt {
            params["cwd"] = resolvePath(cwdOpt)
        }
        if let nameOpt { params["title"] = nameOpt }
        if let descriptionOpt { params["description"] = descriptionOpt }
        if let layoutOpt {
            guard let layoutData = layoutOpt.data(using: .utf8),
                  let layoutObj = try? JSONSerialization.jsonObject(with: layoutData) as? [String: Any] else {
                throw CLIError(message: "\(commandName): --layout value must be a valid JSON object")
            }
            params["layout"] = layoutObj
        }
        try applyFocusOption(focusOpt, defaultValue: false, to: &params)
        let response = try client.sendV2(method: "workspace.create", params: params)
        let wsId = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
        if jsonOutput && honorJSONOutput {
            print(jsonString(formatIDs(response, mode: idFormat)))
        } else {
            print("OK \(wsId)")
        }
        if layoutOpt == nil, let commandText = commandOpt, !wsId.isEmpty {
            let text = unescapeSendText(commandText + "\\n")
            let sendParams: [String: Any] = ["text": text, "workspace_id": wsId]
            _ = try client.sendV2(method: "surface.send_text", params: sendParams)
        }
    }

    func runWorkspaceCloseCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?,
        requireWorkspaceFlag: Bool
    ) throws {
        let target: String?
        if requireWorkspaceFlag {
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "\(commandName) requires --workspace")
            }
            target = workspaceRaw
        } else {
            let (workspaceArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (_, rem1) = parseOption(rem0, name: "--window")
            target = workspaceArg ?? rem1.first(where: { !$0.hasPrefix("--") })
        }

        var params: [String: Any] = [:]
        let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
        if let winId { params["window_id"] = winId }
        let wsId = try normalizeWorkspaceHandle(target, client: client, windowHandle: winId)
        if let wsId { params["workspace_id"] = wsId }
        let payload = try client.sendV2(method: "workspace.close", params: params)
        if let closedWorkspaceId = (payload["workspace_id"] as? String) ?? wsId {
            try? tmuxPruneCompatWorkspaceState(workspaceId: closedWorkspaceId)
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))
    }

    func runWorkspaceSelectCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?,
        requireWorkspaceFlag: Bool
    ) throws {
        let target: String?
        if requireWorkspaceFlag {
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "\(commandName) requires --workspace")
            }
            target = workspaceRaw
        } else {
            let (workspaceArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (_, rem1) = parseOption(rem0, name: "--window")
            target = workspaceArg ?? rem1.first(where: { !$0.hasPrefix("--") })
        }

        var params: [String: Any] = [:]
        let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
        if let winId { params["window_id"] = winId }
        let wsId = try normalizeWorkspaceHandle(target, client: client, windowHandle: winId)
        if !requireWorkspaceFlag {
            guard let wsId else {
                throw CLIError(message: "\(commandName): could not resolve workspace handle")
            }
            params["workspace_id"] = wsId
        } else if let wsId {
            params["workspace_id"] = wsId
        }
        let payload = try client.sendV2(method: "workspace.select", params: params)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))
    }

    func runWorkspaceRenameCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?,
        mode: WorkspaceRenameCommandMode
    ) throws {
        let winId: String?
        let wsId: String
        let title: String

        switch mode {
        case .legacy:
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (windowOpt, rem1) = parseOption(rem0, name: "--window")
            let windowRaw = windowOpt ?? windowOverride
            let workspaceArg = wsArg ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let titleArgs = rem1.dropFirst(rem1.first == "--" ? 1 : 0)
            title = titleArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CLIError(message: "\(commandName) requires a title")
            }
            winId = try normalizeWindowHandle(windowRaw, client: client)
            wsId = try resolveWorkspaceId(workspaceArg, client: client, windowHandle: winId)

        case .namespace:
            let (titleOpt, rem0) = parseOption(commandArgs, name: "--title")
            let (workspaceArg, rem1) = parseOption(rem0, name: "--workspace")
            let (_, rem2) = parseOption(rem1, name: "--window")
            let positional = rem2.first(where: { !$0.hasPrefix("--") })
            let target = workspaceArg ?? positional
            guard let titleOpt else {
                throw CLIError(message: "\(commandName) requires --title <new>")
            }
            title = titleOpt
            winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
            guard let normalizedWorkspaceId = try normalizeWorkspaceHandle(target, client: client, windowHandle: winId) else {
                throw CLIError(message: "\(commandName): could not resolve workspace handle")
            }
            wsId = normalizedWorkspaceId
        }

        var params: [String: Any] = ["title": title, "workspace_id": wsId]
        if let winId { params["window_id"] = winId }
        let payload = try client.sendV2(method: "workspace.rename", params: params)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))
    }

}
