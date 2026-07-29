import Foundation

extension CMUXCLI {
    func tmuxEnrichContextWithGeometry(
        _ context: inout [String: String],
        pane: [String: Any],
        containerFrame: [String: Any]?
    ) {
        let isFocused = boolFromAny(pane["focused"]) == true
        context["pane_active"] = isFocused ? "1" : "0"

        guard let columns = intFromAny(pane["columns"]),
              let rows = intFromAny(pane["rows"]) else { return }

        context["pane_width"] = String(columns)
        context["pane_height"] = String(rows)

        let cellW = intFromAny(pane["cell_width_px"]) ?? 0
        let cellH = intFromAny(pane["cell_height_px"]) ?? 0
        guard cellW > 0, cellH > 0 else { return }

        if let frame = pane["pixel_frame"] as? [String: Any] {
            let px = (frame["x"] as? NSNumber)?.doubleValue ?? (frame["x"] as? Double) ?? 0
            let py = (frame["y"] as? NSNumber)?.doubleValue ?? (frame["y"] as? Double) ?? 0
            context["pane_left"] = String(Int(px) / cellW)
            context["pane_top"] = String(Int(py) / cellH)
        }

        if let cf = containerFrame {
            let cw = (cf["width"] as? NSNumber)?.doubleValue ?? (cf["width"] as? Double) ?? 0
            let ch = (cf["height"] as? NSNumber)?.doubleValue ?? (cf["height"] as? Double) ?? 0
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
            let quotedCwd = tmuxShellQuote(resolvePath(trimmedCwd))
            pieces.append("cd -- \(quotedCwd)")
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

    /// Returns a pane start-command that the surface can exec correctly.
    ///
    /// cmux hands a respawn/start command to the surface as the pane's process
    /// command. On macOS, Ghostty execs that command via `exec -l <command>`
    /// (see ghostty/src/termio/Exec.zig), which only works when `<command>` is a
    /// single executable. tmux shell-commands are arbitrary shell expressions —
    /// Claude Code agent-team teammates respawn with `cd <dir> && env … <claude> …`
    /// — so `exec -l cd …` tries to exec the `cd` builtin as a binary, fails, and
    /// the pane exits before the real command runs; that is why Claude Code
    /// 2.1.183 teammates never opened a split pane (issue #6447).
    ///
    /// Every command is run through `/bin/sh -c '<command>'`, so Ghostty execs a
    /// shell rather than a builtin/expression/assignment-prefix. The whole command
    /// is single-quoted, so it round-trips verbatim regardless of operators or
    /// quoting — there is no attempt to classify which commands "need" a shell,
    /// which was unreliable (tmux shell-commands can hide operators with no
    /// surrounding whitespace). Commands that are already a shell invocation (e.g.
    /// OMO's `/bin/sh -c "…"`) are simply run through one more shell, which execs
    /// straight into them.
    ///
    /// A POSIX shell (`/bin/sh`) is used deliberately rather than the user's
    /// `$SHELL`: the commands being wrapped are POSIX `sh` syntax (Claude Code's
    /// `cd … && env …`, and the no-command fallback `exec ${SHELL:-/bin/sh} -l`),
    /// and `csh`/`tcsh` login shells cannot parse `${VAR:-default}` parameter
    /// expansion or `NAME=value` command prefixes. `/bin/sh` is always present and
    /// runs the bodies correctly for every user. `-l` is not passed (`/bin/sh`
    /// does not take it); on macOS Ghostty already supplies a login-style argv0.
    func tmuxShellInvokedStartCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return command }
        return "/bin/sh -c \(tmuxShellQuote(trimmed))"
    }

    /// Like `tmuxShellInvokedStartCommand`, but first exports `prependEnv` inside
    /// the wrapping shell so the respawned process — and any `env …`/`exec` it
    /// chains into — inherits those variables. Used to re-supply claude-teams
    /// teammate panes the environment they need (see
    /// `tmuxClaudeTeamsRespawnEnvironment`); with an empty `prependEnv` it is
    /// byte-for-byte identical to `tmuxShellInvokedStartCommand`, so OMO and the
    /// public `respawn-pane` command are unchanged.
    func tmuxRespawnStartCommand(
        _ command: String,
        prependEnv: [(key: String, value: String)]
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return command }
        guard !prependEnv.isEmpty else { return tmuxShellInvokedStartCommand(trimmed) }
        let exports = prependEnv
            .map { "export \($0.key)=\(tmuxShellQuote($0.value))" }
            .joined(separator: "; ")
        return tmuxShellInvokedStartCommand("\(exports); \(trimmed)")
    }

    /// Environment that a claude-teams teammate pane must start with.
    ///
    /// Teammate panes are respawned by cmux's surface layer, not by `cmux
    /// claude-teams`, so they do NOT inherit the launcher environment the lead
    /// got from `configureClaudeTeamsEnvironment`. The one variable that matters
    /// for startup is `CLAUDE_CODE_SANDBOXED`: Claude Code short-circuits its
    /// interactive "Do you trust this folder?" gate on it, and a teammate that
    /// hits that gate hangs forever (its pane opens but it never checks in —
    /// issue #6447). Re-supply it so teammates start the same way the lead does.
    ///
    /// That trust gate is a real safety boundary, so it is only waived when the
    /// user already opted into skipping safety prompts. The opt-in is NOT inferred
    /// from the respawn command text (a `--dangerously-skip-permissions` substring
    /// can appear in a cwd, quoted value, or other non-flag position): the `cmux
    /// claude-teams` launcher makes that decision once from its own argv and records
    /// it in `CMUX_CLAUDE_TEAMS_SANDBOXED` (see `claudeTeamsExtraEnvVars`). That
    /// launcher env is propagated by the tmux shim to this `__tmux-compat` process,
    /// and is set only inside an opted-in claude-teams session, so OMO and the
    /// public `respawn-pane` command never see it and are unaffected.
    ///
    /// The bypass is deliberately per-launch and is NOT baked into the pane's
    /// `tmux_start_command` (kept raw for display / OMX-HUD / `#{pane_start_command}`),
    /// so it is not carried into session persistence/restore. That is intentional:
    /// a restored teammate pane is an orphan (its team/parent session is gone after
    /// an app restart) and is not a fresh `--dangerously-skip-permissions` opt-in, so
    /// it correctly falls back to Claude's trust prompt rather than silently bypassing
    /// the trust boundary outside an explicit opt-in.
    func tmuxClaudeTeamsRespawnEnvironment() -> [(key: String, value: String)] {
        guard ProcessInfo.processInfo.environment["CMUX_CLAUDE_TEAMS_SANDBOXED"] == "1" else {
            return []
        }
        return [(key: "CLAUDE_CODE_SANDBOXED", value: "1")]
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
            let quotedCwd = tmuxShellQuote(resolvePath(cwd))
            lines.append("cd -- \(quotedCwd) || exit $?")
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
