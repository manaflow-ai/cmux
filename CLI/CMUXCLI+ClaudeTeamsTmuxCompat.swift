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


// MARK: - claude-teams tmux compat session
extension CMUXCLI {
    func runClaudeTeamsTmuxCompat(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (command, rawArgs) = try splitTmuxCommand(commandArgs)

        switch command {
        case "new-session", "new":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-n", "-s"],
                boolFlags: ["-A", "-d", "-P"]
            )
            if parsed.hasFlag("-A") {
                throw CLIError(message: "new-session -A is not supported in cmux claude-teams mode")
            }
            var params: [String: Any] = ["focus": false]
            if let cwd = parsed.value("-c") {
                params["cwd"] = resolvePath(cwd)
            }
            let created = try client.sendV2(method: "workspace.create", params: params)
            guard let workspaceId = created["workspace_id"] as? String else {
                throw CLIError(message: "workspace.create did not return workspace_id")
            }
            if let title = parsed.value("-n") ?? parsed.value("-s"),
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": title
                ])
            }
            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
            }

        case "new-window", "neww":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-n", "-t"],
                boolFlags: ["-d", "-P"]
            )
            if parsed.value("-t") != nil {
                throw CLIError(message: "new-window -t is not supported in cmux claude-teams mode")
            }
            var params: [String: Any] = ["focus": false]
            if let cwd = parsed.value("-c") {
                params["cwd"] = resolvePath(cwd)
            }
            let created = try client.sendV2(method: "workspace.create", params: params)
            guard let workspaceId = created["workspace_id"] as? String else {
                throw CLIError(message: "workspace.create did not return workspace_id")
            }
            if let title = parsed.value("-n"),
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": title
                ])
            }
            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
            }

        case "split-window", "splitw":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-l", "-t"],
                boolFlags: ["-P", "-b", "-d", "-f", "-h", "-v"]
            )
            let isOMXHud = tmuxCommandLooksLikeOMXHud(parsed.positional)
            if isOMXHud && tmuxOMXHudConfigDisablesHud(cwd: parsed.value("-c")) {
                tmuxWriteDebugDiagnostic(
                    "OMX HUD disabled by config; cwd=\(parsed.value("-c") ?? "<default>") command=\(parsed.positional.joined(separator: " "))"
                )
                return
            }

            var target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            var direction: String
            var anchoredCallerSurfaceId: String?
            if parsed.hasFlag("-h") {
                direction = parsed.hasFlag("-b") ? "left" : "right"
            } else {
                direction = parsed.hasFlag("-b") ? "up" : "down"
            }

            // Claude's agent teams targets arbitrary panes (from list-panes),
            // not necessarily the leader pane from TMUX_PANE. Override the
            // target to anchor all teammate splits to the leader surface.
            // Only apply caller anchoring when the caller's workspace resolves
            // successfully. Falling back to target.workspaceId would pair
            // the caller's surface with a different workspace, creating an
            // invalid cross-workspace split.
            if parsed.hasFlag("-h"),
               let callerWorkspace = tmuxCallerWorkspaceHandle(),
               let wsId = try? resolveWorkspaceId(callerWorkspace, client: client),
               let anchoredTarget = tmuxAnchoredSplitTarget(workspaceId: wsId, client: client) {
                target = (wsId, nil, anchoredTarget.targetSurfaceId)
                direction = anchoredTarget.direction
                anchoredCallerSurfaceId = anchoredTarget.callerSurfaceId
            }

            // Keep the leader pane focused while agents spawn beside it.
            // -d explicitly means "don't focus the new pane".
            let focusNewPane = !parsed.hasFlag("-d")
            var splitParams: [String: Any] = [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId,
                "direction": direction,
                "focus": focusNewPane
            ]
            if let cwd = parsed.value("-c")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cwd.isEmpty {
                splitParams["working_directory"] = resolvePath(cwd)
            }
            let startupScript = isOMXHud
                ? tmuxStartupScript(commandTokens: parsed.positional, cwd: parsed.value("-c"))
                : nil
            if let startupScript {
                splitParams["initial_command"] = startupScript
            }
            if let startCommand = tmuxStartCommand(commandTokens: parsed.positional) {
                splitParams["tmux_start_command"] = startCommand
            }
            let sizeTargetPaneId = target.paneId
                ?? (try? tmuxResolvePaneTarget(parsed.value("-t"), client: client).paneId)
                ?? (try? tmuxPaneIdForSurface(
                    workspaceId: target.workspaceId,
                    surfaceId: target.surfaceId,
                    client: client
                ))
            if let targetPaneId = sizeTargetPaneId,
               let targetCells = tmuxSplitSizeCells(parsed.value("-l")),
               let dividerPosition = try? tmuxInitialDividerPosition(
                    workspaceId: target.workspaceId,
                    paneId: targetPaneId,
                    newPaneDirection: direction,
                    targetCells: targetCells,
                    client: client
               ) {
                splitParams["initial_divider_position"] = dividerPosition
            }
            let created = try client.sendV2(method: "surface.split", params: splitParams)
            guard let surfaceId = created["surface_id"] as? String else {
                throw CLIError(message: "surface.split did not return surface_id")
            }
            let paneId = created["pane_id"] as? String

            // Track the newly created pane for main-vertical layout.
            if !isOMXHud {
                var updatedStore = loadTmuxCompatStore()
                updatedStore.lastSplitSurface[target.workspaceId] = surfaceId
                if updatedStore.mainVerticalLayouts[target.workspaceId] != nil {
                    updatedStore.mainVerticalLayouts[target.workspaceId]?.lastColumnSurfaceId = surfaceId
                } else if direction == "right", let anchoredCallerSurfaceId {
                    // First right split created the column; seed main-vertical
                    // state so subsequent splits stack downward.
                    updatedStore.mainVerticalLayouts[target.workspaceId] = MainVerticalState(
                        mainSurfaceId: anchoredCallerSurfaceId,
                        lastColumnSurfaceId: surfaceId
                    )
                }
                try saveTmuxCompatStore(updatedStore)

                // Equalize vertical splits so teammate panes are evenly distributed.
                // Use orientation: "vertical" to only equalize the agent column,
                // preserving the leader/column horizontal divider position.
                _ = try? client.sendV2(method: "workspace.equalize_splits", params: [
                    "workspace_id": target.workspaceId,
                    "orientation": "vertical"
                ])
            }

            if startupScript == nil,
               let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": target.workspaceId,
                    "surface_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(
                    workspaceId: target.workspaceId,
                    paneId: paneId,
                    surfaceId: surfaceId,
                    client: client
                )
                let fallback = context["pane_id"] ?? surfaceId
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "select-window", "selectw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.select", params: ["workspace_id": workspaceId])

        case "select-pane", "selectp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-P", "-T", "-t"], boolFlags: [])
            if parsed.value("-P") != nil || parsed.value("-T") != nil {
                return
            }
            let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "pane.focus", params: [
                "workspace_id": target.workspaceId,
                "pane_id": target.paneId
            ])

        case "kill-window", "killw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])
            try? tmuxPruneCompatWorkspaceState(workspaceId: workspaceId)

        case "kill-pane", "killp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "surface.close", params: [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId
            ])
            try? tmuxPruneCompatSurfaceState(
                workspaceId: target.workspaceId,
                surfaceId: target.surfaceId,
                client: client
            )
            // Re-equalize the agent column after removing a pane
            _ = try? client.sendV2(method: "workspace.equalize_splits", params: [
                "workspace_id": target.workspaceId,
                "orientation": "vertical"
            ])

        case "respawn-pane", "respawnp":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-t"],
                boolFlags: ["-k"]
            )
            guard parsed.hasFlag("-k") else {
                throw CLIError(message: String(
                    localized: "cli.tmuxCompat.respawnPane.requiresForce",
                    defaultValue: "respawn-pane requires -k in cmux tmux compatibility mode"
                ))
            }
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let commandText: String
            if let explicitCommand = tmuxStartCommand(commandTokens: parsed.positional) {
                commandText = explicitCommand
            } else {
                commandText = try tmuxStoredStartCommand(
                    workspaceId: target.workspaceId,
                    surfaceId: target.surfaceId,
                    client: client
                ) ?? "exec ${SHELL:-/bin/sh} -l"
            }
            var params: [String: Any] = [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId,
                "command": commandText,
                "tmux_start_command": commandText
            ]
            if let cwd = parsed.value("-c")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cwd.isEmpty {
                params["working_directory"] = resolvePath(cwd)
            }
            _ = try client.sendV2(method: "surface.respawn", params: params)

        case "send-keys", "send":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: ["-l"])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let text = tmuxSendKeysText(from: parsed.positional, literal: parsed.hasFlag("-l"))
            if !text.isEmpty {
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": target.workspaceId,
                    "surface_id": target.surfaceId,
                    "text": text
                ])
            }

        case "capture-pane", "capturep":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-E", "-S", "-t"],
                boolFlags: ["-J", "-N", "-p"]
            )
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            var params: [String: Any] = [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId,
                "scrollback": true
            ]
            if let start = parsed.value("-S"), let lines = Int(start), lines < 0 {
                params["lines"] = abs(lines)
            }
            let payload = try client.sendV2(method: "surface.read_text", params: params)
            let text = (payload["text"] as? String) ?? ""
            if parsed.hasFlag("-p") {
                print(text)
            } else {
                var store = loadTmuxCompatStore()
                store.buffers["default"] = text
                try saveTmuxCompatStore(store)
            }

        case "display-message", "display", "displayp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: ["-p"])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            var context = try tmuxFormatContext(
                workspaceId: target.workspaceId,
                paneId: target.paneId,
                surfaceId: target.surfaceId,
                client: client
            )
            // Enrich with geometry for format strings like #{pane_width},#{window_width}
            let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": target.workspaceId])
            let panesList = panePayload["panes"] as? [[String: Any]] ?? []
            let containerFrame = panePayload["container_frame"] as? [String: Any]
            if let targetPaneId = target.paneId,
               let matchingPane = panesList.first(where: { ($0["id"] as? String) == targetPaneId }) {
                tmuxEnrichContextWithGeometry(&context, pane: matchingPane, containerFrame: containerFrame)
            } else if let firstPane = panesList.first(where: { boolFromAny($0["focused"]) == true }) ?? panesList.first {
                tmuxEnrichContextWithGeometry(&context, pane: firstPane, containerFrame: containerFrame)
            }
            let format = parsed.positional.isEmpty ? parsed.value("-F") : parsed.positional.joined(separator: " ")
            let rendered = tmuxRenderFormat(format, context: context, fallback: "")
            if parsed.hasFlag("-p") || !rendered.isEmpty {
                print(rendered)
            }

        case "list-windows", "lsw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: [])
            let items = try tmuxWorkspaceItems(client: client)
            for item in items {
                guard let workspaceId = item["id"] as? String else { continue }
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                let fallback = [
                    context["window_index"] ?? "?",
                    context["window_name"] ?? workspaceId
                ].joined(separator: " ")
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "list-panes", "lsp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: [])
            // Resolve target: can be a pane (%uuid) or workspace. In tmux,
            // list-panes -t %<pane> lists all panes in the window containing that pane.
            let workspaceId: String
            if let target = parsed.value("-t"), tmuxPaneSelector(from: target) != nil {
                let paneTarget = try tmuxResolvePaneTarget(target, client: client)
                workspaceId = paneTarget.workspaceId
            } else {
                workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            }
            let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
            let panes = payload["panes"] as? [[String: Any]] ?? []
            let containerFrame = payload["container_frame"] as? [String: Any]
            for pane in panes {
                guard let paneId = pane["id"] as? String else { continue }
                var context = try tmuxFormatContext(workspaceId: workspaceId, paneId: paneId, client: client)
                tmuxEnrichContextWithGeometry(&context, pane: pane, containerFrame: containerFrame)
                if tmuxFormatRequestsPaneCommand(parsed.value("-F")),
                   context["pane_start_command"] == nil,
                   let surfaceId = context["surface_id"],
                   let legacyHudStartCommand = tmuxLegacyOMXHudStartCommand(
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        client: client
                   ) {
                    context["pane_start_command"] = legacyHudStartCommand
                    context["pane_current_command"] = tmuxCurrentCommandName(from: legacyHudStartCommand)
                }
                let fallback = context["pane_id"] ?? paneId
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "rename-window", "renamew":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let title = parsed.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CLIError(message: "rename-window requires a title")
            }
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.rename", params: [
                "workspace_id": workspaceId,
                "title": title
            ])

        case "resize-pane", "resizep":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-t", "-x", "-y"],
                boolFlags: ["-D", "-L", "-R", "-U"]
            )
            let hasDirectionalFlags = parsed.hasFlag("-L")
                || parsed.hasFlag("-R")
                || parsed.hasFlag("-U")
                || parsed.hasFlag("-D")
            let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)
            let isAbsoluteHeightOnlyResize = !hasDirectionalFlags
                && parsed.value("-x") == nil
                && parsed.value("-y") != nil
            if isAbsoluteHeightOnlyResize,
               tmuxPaneLooksLikeOMXHud(
                    workspaceId: target.workspaceId,
                    paneId: target.paneId,
                    client: client
               ) {
                return
            }

            if !hasDirectionalFlags, let absWidth = parsed.value("-x").flatMap({ Int($0.replacingOccurrences(of: "%", with: "")) }) {
                // Absolute width: resize-pane -t <pane> -x <columns>
                // Compute pixel delta from current width to desired width.
                try tmuxResizePaneToCells(
                    workspaceId: target.workspaceId,
                    paneId: target.paneId,
                    targetCells: absWidth,
                    currentCellsKey: "columns",
                    cellSizeKey: "cell_width_px",
                    client: client
                )
            } else if !hasDirectionalFlags, let absHeight = parsed.value("-y").flatMap({ Int($0.replacingOccurrences(of: "%", with: "")) }) {
                try tmuxResizePaneToCells(
                    workspaceId: target.workspaceId,
                    paneId: target.paneId,
                    targetCells: absHeight,
                    currentCellsKey: "rows",
                    cellSizeKey: "cell_height_px",
                    client: client
                )
            } else if hasDirectionalFlags {
                let direction: String
                if parsed.hasFlag("-L") {
                    direction = "left"
                } else if parsed.hasFlag("-U") {
                    direction = "up"
                } else if parsed.hasFlag("-D") {
                    direction = "down"
                } else {
                    direction = "right"
                }
                let rawAmount = (parsed.value("-x") ?? parsed.value("-y") ?? "5")
                    .replacingOccurrences(of: "%", with: "")
                let amount = Int(rawAmount) ?? 5
                _ = try client.sendV2(method: "pane.resize", params: [
                    "workspace_id": target.workspaceId,
                    "pane_id": target.paneId,
                    "direction": direction,
                    "amount": max(1, amount)
                ])
            }

        case "wait-for":
            try runTmuxCompatCommand(
                command: "wait-for",
                commandArgs: rawArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )

        case "last-pane":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "pane.last", params: ["workspace_id": workspaceId])

        case "show-buffer", "showb":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
            let name = parsed.value("-b") ?? "default"
            let store = loadTmuxCompatStore()
            if let buffer = store.buffers[name] {
                print(buffer)
            }

        case "show-options", "show-option", "show":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-t"],
                boolFlags: ["-g", "-q", "-s", "-v", "-w"]
            )
            let optionName = parsed.positional.last ?? ""
            guard optionName == "extended-keys" else {
                throw CLIError(message: "Unsupported tmux compatibility command: \(command) \(optionName)")
            }
            let value = "on"
            if parsed.hasFlag("-v") {
                print(value)
            } else {
                print("\(optionName) \(value)")
            }

        case "save-buffer", "saveb":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
            let name = parsed.value("-b") ?? "default"
            let store = loadTmuxCompatStore()
            guard let buffer = store.buffers[name] else {
                throw CLIError(message: "Buffer not found: \(name)")
            }
            if let outputPath = parsed.positional.last, !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try buffer.write(toFile: resolvePath(outputPath), atomically: true, encoding: .utf8)
            } else {
                print(buffer)
            }

        case "last-window", "next-window", "previous-window", "set-hook", "set-buffer", "list-buffers":
            try runTmuxCompatCommand(
                command: command,
                commandArgs: rawArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )

        case "has-session", "has":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            _ = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)

        case "select-layout":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let layoutName = parsed.positional.first ?? ""
            // select-layout -t accepts pane targets (e.g. %1) in real tmux.
            // Try pane target first, then workspace target. Only fall back to
            // the caller's current workspace when no -t was provided; an
            // explicit -t that fails to resolve should error, not silently
            // apply to the wrong workspace.
            let workspaceId: String = {
                if let target = parsed.value("-t") {
                    if let resolved = try? tmuxResolvePaneTarget(target, client: client) {
                        return resolved.workspaceId
                    }
                    return (try? tmuxResolveWorkspaceTarget(target, client: client)) ?? ""
                }
                return (try? tmuxResolveWorkspaceTarget(nil, client: client)) ?? ""
            }()
            guard !workspaceId.isEmpty else {
                throw CLIError(message: "Could not resolve workspace for select-layout")
            }
            if layoutName == "main-vertical" || layoutName == "main-horizontal" {
                // For main-* layouts, only equalize the agent column (vertical splits),
                // not the top-level horizontal split between main and agents.
                let orientation = layoutName == "main-vertical" ? "vertical" : "horizontal"
                _ = try? client.sendV2(method: "workspace.equalize_splits", params: [
                    "workspace_id": workspaceId,
                    "orientation": orientation
                ])
            } else {
                // For tiled/even-* layouts, equalize everything
                _ = try? client.sendV2(method: "workspace.equalize_splits", params: ["workspace_id": workspaceId])
            }
            if layoutName == "main-vertical" {
                if let callerSurface = tmuxCallerSurfaceHandle() {
                    var store = loadTmuxCompatStore()
                    let existingColumn = store.mainVerticalLayouts[workspaceId]?.lastColumnSurfaceId
                    let seedColumn = existingColumn ?? store.lastSplitSurface[workspaceId]
                    store.mainVerticalLayouts[workspaceId] = MainVerticalState(
                        mainSurfaceId: callerSurface,
                        lastColumnSurfaceId: seedColumn
                    )
                    try saveTmuxCompatStore(store)
                }
            } else if !layoutName.isEmpty {
                // Non-main-vertical layout selected: clear stale state so
                // future splits don't incorrectly redirect to the old column.
                try tmuxPruneCompatWorkspaceState(workspaceId: workspaceId)
            }

        case "set-option", "set", "set-window-option", "setw", "source-file", "refresh-client", "attach-session", "detach-client":
            return

        case "-V", "-v":
            print("tmux 3.4")
            return

        default:
            throw CLIError(message: "Unsupported tmux compatibility command: \(command)")
        }
    }

}
