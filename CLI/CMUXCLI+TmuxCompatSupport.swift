import Foundation

extension CMUXCLI {
    func tmuxEnrichContextWithGeometry(
        _ context: inout [String: String],
        pane: [String: Any],
        containerFrame: [String: Any]?
    ) {
        let isFocused = (pane["focused"] as? Bool) == true
        context["pane_active"] = isFocused ? "1" : "0"

        guard let columns = pane["columns"] as? Int,
              let rows = pane["rows"] as? Int else { return }

        context["pane_width"] = String(columns)
        context["pane_height"] = String(rows)

        let cellW = pane["cell_width_px"] as? Int ?? 0
        let cellH = pane["cell_height_px"] as? Int ?? 0
        guard cellW > 0, cellH > 0 else { return }

        if let frame = pane["pixel_frame"] as? [String: Any] {
            let px = frame["x"] as? Double ?? 0
            let py = frame["y"] as? Double ?? 0
            context["pane_left"] = String(Int(px) / cellW)
            context["pane_top"] = String(Int(py) / cellH)
        }

        if let cf = containerFrame {
            let cw = cf["width"] as? Double ?? 0
            let ch = cf["height"] as? Double ?? 0
            context["window_width"] = String(max(Int(cw) / cellW, 1))
            context["window_height"] = String(max(Int(ch) / cellH, 1))
        }
    }

    func tmuxShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func tmuxShellCommandBody(commandTokens: [String], cwd: String?) -> String? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandText = commandTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmedCwd?.isEmpty == false) || !commandText.isEmpty else {
            return nil
        }

        var pieces: [String] = []
        if let trimmedCwd, !trimmedCwd.isEmpty {
            pieces.append("cd -- \(tmuxShellQuote(resolvePath(trimmedCwd)))")
        }
        if !commandText.isEmpty {
            pieces.append(commandText)
        }
        return pieces.joined(separator: " && ")
    }

    func tmuxShellCommandText(commandTokens: [String], cwd: String?) -> String? {
        tmuxShellCommandBody(commandTokens: commandTokens, cwd: cwd).map { $0 + "\r" }
    }

    func tmuxStartCommand(commandTokens: [String]) -> String? {
        let commandText = commandTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return commandText.isEmpty ? nil : commandText
    }

    func tmuxShellWords(_ commandText: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaping = false

        for character in commandText {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" && !inSingleQuote {
                escaping = true
                continue
            }
            if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }
            if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }
            if character.isWhitespace && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }

        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    func tmuxLooksLikeShellAssignment(_ token: String) -> Bool {
        guard let equalsIndex = token.firstIndex(of: "="), equalsIndex != token.startIndex else {
            return false
        }
        let name = token[..<equalsIndex]
        guard let first = name.first, first == "_" || first.isLetter else {
            return false
        }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    func tmuxCurrentCommandName(from startCommand: String) -> String? {
        for token in tmuxShellWords(startCommand) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if tmuxLooksLikeShellAssignment(trimmed) { continue }
            let lower = trimmed.lowercased()
            if lower == "env" || lower == "exec" || lower == "command" { continue }
            let basename = (trimmed as NSString).lastPathComponent
            return basename.isEmpty ? trimmed : basename
        }
        return nil
    }

    func tmuxFormatRequestsPaneCommand(_ format: String?) -> Bool {
        guard let format else { return false }
        return format.contains("#{pane_start_command}") || format.contains("#{pane_current_command}")
    }

    func tmuxLegacyOMXHudStartCommand(
        workspaceId: String,
        surfaceId: String,
        client: SocketClient
    ) -> String? {
        guard let payload = try? client.sendV2(method: "surface.read_text", params: [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "lines": 4
        ]),
            let text = payload["text"] as? String else {
            return nil
        }
        let lower = text.lowercased()
        guard lower.contains("[omx#"),
              lower.contains("turns:"),
              lower.contains("session:") else {
            return nil
        }
        return "node omx.js hud --watch"
    }

    func tmuxPaneLooksLikeOMXHud(workspaceId: String, paneId: String, client: SocketClient) -> Bool {
        guard let surfaceId = try? tmuxSelectedSurfaceId(
            workspaceId: workspaceId,
            paneId: paneId,
            client: client
        ) else {
            return false
        }

        if let payload = try? client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId]),
           let surfaces = payload["surfaces"] as? [[String: Any]],
           let surface = surfaces.first(where: { ($0["id"] as? String) == surfaceId }) {
            let paneStartCommand = [
                surface["tmux_start_command"],
                surface["pane_start_command"],
                surface["initial_command"]
            ]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }

            if let paneStartCommand,
               tmuxCommandLooksLikeOMXHud(tmuxShellWords(paneStartCommand)) {
                return true
            }
        }

        return tmuxLegacyOMXHudStartCommand(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            client: client
        ) != nil
    }

    func tmuxStartupScript(commandTokens: [String], cwd: String?) -> String? {
        let commandText = commandTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandText.isEmpty else {
            return nil
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tmux-command-\(UUID().uuidString.lowercased()).sh")
        var lines = [
            "#!/bin/sh",
            "rm -f -- \"$0\" 2>/dev/null || true"
        ]
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            lines.append("cd -- \(tmuxShellQuote(resolvePath(cwd))) || exit $?")
        }
        lines.append("exec \"${SHELL:-/bin/sh}\" -lc \(tmuxShellQuote(commandText))")
        do {
            try (lines.joined(separator: "\n") + "\n").write(
                to: scriptURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
            return scriptURL.path
        } catch {
            return nil
        }
    }

    func tmuxSplitSizeCells(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("%") else { return nil }
        return Int(trimmed)
    }

    func tmuxResizePaneToCells(
        workspaceId: String,
        paneId: String,
        targetCells: Int,
        currentCellsKey: String,
        cellSizeKey: String,
        client: SocketClient
    ) throws {
        guard targetCells > 0 else { return }
        let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
        let panes = panePayload["panes"] as? [[String: Any]] ?? []
        guard let matchingPane = panes.first(where: { ($0["id"] as? String) == paneId }),
              let cellSize = intFromAny(matchingPane[cellSizeKey]), cellSize > 0 else {
            return
        }
        let axis = currentCellsKey == "columns" ? "horizontal" : "vertical"
        _ = try client.sendV2(method: "pane.resize", params: [
            "workspace_id": workspaceId,
            "pane_id": paneId,
            "absolute_axis": axis,
            "target_pixels": targetCells * cellSize
        ])
    }

    func tmuxInitialDividerPosition(
        workspaceId: String,
        paneId: String,
        newPaneDirection: String,
        targetCells: Int,
        client: SocketClient
    ) throws -> Double? {
        guard targetCells > 0 else { return nil }
        let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
        let panes = panePayload["panes"] as? [[String: Any]] ?? []
        guard let matchingPane = panes.first(where: { ($0["id"] as? String) == paneId }) else {
            return nil
        }

        let currentCells: Int?
        switch newPaneDirection {
        case "left", "right":
            currentCells = intFromAny(matchingPane["columns"])
        default:
            currentCells = intFromAny(matchingPane["rows"])
        }

        guard let currentCells, currentCells > 0 else { return nil }
        let requested = min(targetCells, max(currentCells - 1, 1))
        let rawPosition: Double
        switch newPaneDirection {
        case "left", "up":
            rawPosition = Double(requested) / Double(currentCells)
        default:
            rawPosition = Double(currentCells - requested) / Double(currentCells)
        }
        return min(max(rawPosition, 0.1), 0.9)
    }

    func tmuxPaneIdForSurface(workspaceId: String, surfaceId: String, client: SocketClient) throws -> String? {
        let payload = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        return surfaces.first { ($0["id"] as? String) == surfaceId }?["pane_id"] as? String
    }

    func tmuxSpecialKeyText(_ token: String) -> String? {
        switch token.lowercased() {
        case "enter", "c-m", "kpenter":
            return "\r"
        case "tab", "c-i":
            return "\t"
        case "space":
            return " "
        case "bspace", "backspace":
            return "\u{7f}"
        case "escape", "esc", "c-[":
            return "\u{1b}"
        case "c-c":
            return "\u{03}"
        case "c-d":
            return "\u{04}"
        case "c-z":
            return "\u{1a}"
        case "c-l":
            return "\u{0c}"
        default:
            return nil
        }
    }

    func tmuxSendKeysText(from tokens: [String], literal: Bool) -> String {
        if literal {
            return tokens.joined(separator: " ")
        }

        var result = ""
        var pendingSpace = false
        for token in tokens {
            if let special = tmuxSpecialKeyText(token) {
                result += special
                pendingSpace = false
                continue
            }
            if pendingSpace {
                result += " "
            }
            result += token
            pendingSpace = true
        }
        return result
    }

    func prependPathEntries(_ newEntries: [String], to currentPath: String?) -> String {
        var ordered: [String] = []
        var seen: Set<String> = []
        for entry in newEntries + (currentPath?.split(separator: ":").map(String.init) ?? []) where !entry.isEmpty {
            if seen.insert(entry).inserted {
                ordered.append(entry)
            }
        }
        return ordered.joined(separator: ":")
    }

    struct TmuxCompatFocusedContext {
        let socketPath: String
        let workspaceId: String
        let windowId: String?
        let paneHandle: String
        let paneId: String?
        let surfaceId: String?
    }
}
