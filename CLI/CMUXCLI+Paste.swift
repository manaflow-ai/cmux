import Darwin
import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    /// Parsed `cmux paste` arguments: the target options stay raw so the shared
    /// handle normalizers resolve them exactly like `cmux send`.
    struct PasteCommandArguments: Equatable {
        var workspace: String?
        var surface: String?
        var window: String?
        var submit = false
        /// `--force`: skip the draft and dialog check.
        var force = false
        /// Positional text, or nil when the text comes from stdin (no positional
        /// text, or a lone `-` before any `--` separator).
        var text: String?
    }

    func parsePasteCommandArguments(_ commandArgs: [String]) throws -> PasteCommandArguments {
        let (workspace, rem0) = parseOption(commandArgs, name: "--workspace")
        let (surface, rem1) = parseOption(rem0, name: "--surface")
        let (window, rem2) = parseOption(rem1, name: "--window")
        var parsed = PasteCommandArguments(workspace: workspace, surface: surface, window: window)
        var positional: [String] = []
        var readsStandardInput = false
        var pastTerminator = false
        for arg in rem2 {
            if pastTerminator {
                positional.append(arg)
                continue
            }
            switch arg {
            case "--":
                pastTerminator = true
            case "--submit":
                parsed.submit = true
            case "--force":
                parsed.force = true
            case "-":
                readsStandardInput = true
            default:
                // Everything here lands in an agent prompt, so a mistyped flag
                // (`--sumbit`, `-s`) or an option missing its value must fail
                // rather than be pasted. Text that starts with "-" goes after
                // the `--` terminator.
                if arg.hasPrefix("-") {
                    throw CLIError(message: String(
                        format: String(
                            localized: "cli.paste.error.unknownFlag",
                            defaultValue: "paste: unknown flag or missing value: %@ (put text that starts with - after a -- separator)"
                        ),
                        arg
                    ))
                }
                positional.append(arg)
            }
        }
        if readsStandardInput, !positional.isEmpty {
            throw CLIError(message: String(
                localized: "cli.paste.error.textAndStdin",
                defaultValue: "paste: pass text or -, not both"
            ))
        }
        parsed.text = positional.isEmpty ? nil : positional.joined(separator: " ")
        return parsed
    }

    /// `cmux paste`: deliver text through the terminal's paste path.
    ///
    /// Unlike `cmux send`, which types the text as keystrokes (every newline
    /// is Enter, `\n`-style escapes are rewritten), the text goes to
    /// `terminal.paste`, the same path as Cmd+V. Ghostty then encodes it like
    /// any paste: when the program has enabled bracketed paste (mode 2004) it
    /// arrives as one paste with newlines kept; otherwise newlines become `\r`.
    /// In both cases unsafe control bytes (ESC, NUL, BS, DEL, ^C, ^U, ^W, ^Z
    /// and similar) are replaced with spaces. The CLI itself passes the text
    /// through unchanged.
    ///
    /// Stdin, when used, is drained before the socket connects (see
    /// ``prepareStandardInputBeforeSocket(command:commandArgs:)``).
    func runPasteCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let parsed = try parsePasteCommandArguments(commandArgs)
        let text: String
        if let positional = parsed.text {
            text = positional
        } else {
            text = try pasteTextFromStandardInput()
        }
        guard !text.isEmpty else {
            throw CLIError(message: Self.pasteMissingTextMessage)
        }
        try deliverTerminalPaste(
            text: text,
            command: "paste",
            workspace: parsed.workspace,
            surface: parsed.surface,
            windowRaw: parsed.window ?? windowOverride,
            submit: parsed.submit,
            force: parsed.force,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }

    /// Sends `text` unchanged through `terminal.paste` and prints the result.
    /// Shared by `cmux paste` and `cmux send --paste`, so both resolve their
    /// targets and report delivery the same way. `command` names the caller
    /// in the size-limit error. Unless `force` is set, refuses to paste over
    /// a draft or into an open dialog (see ``ensureAgentPromptIsFree``).
    @discardableResult
    func deliverTerminalPaste(
        text: String,
        command: String,
        workspace: String?,
        surface: String?,
        windowRaw: String?,
        submit: Bool,
        force: Bool,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        emitOutput: Bool = true
    ) throws -> [String: Any] {
        try Self.ensureTextFitsSocketRequest(text, command: command)

        var params: [String: Any] = [
            "text": text,
            // `return` lets the host pick the agent-aware submit key (for
            // example an agent-specific key for a multi-line prompt).
            "submit_key": submit ? "return" : "none",
        ]
        let target = try terminalTargetParams(
            workspace: workspace,
            surface: surface,
            windowRaw: windowRaw,
            client: client
        )
        params.merge(target) { _, new in new }
        if !force {
            try ensureAgentPromptIsFree(for: .text, command: command, target: params, client: client)
        }

        let payload = try client.sendV2(method: "terminal.paste", params: params)
        if emitOutput, submit, (payload["submitted"] as? Bool) != true {
            // The text is already at the prompt, so this is a warning rather
            // than a failure: a caller that retried would paste it twice.
            let reason = (payload["submit_error"] as? String) ?? "unknown"
            let warning = String(
                format: String(
                    localized: "cli.paste.warning.submitFailed",
                    defaultValue: "warning: text was pasted but the submit key was not sent (%@)"
                ),
                reason
            )
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
        if emitOutput {
            printV2Payload(
                payload,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                fallbackText: pasteSummary(payload, idFormat: idFormat)
            )
        }
        return payload
    }

    /// Builds the resolved target shared by paste, submit, and the screen/state
    /// probes. The resulting UUID selectors are also the selectors accepted by
    /// the SSH relay, so submit does not need a local-only focus operation.
    private func terminalTargetParams(
        workspace: String?,
        surface: String?,
        windowRaw: String?,
        client: SocketClient
    ) throws -> [String: Any] {
        let workspaceArg = workspace
            ?? Self.callerWorkspaceForSurfaceHandle(surface, windowRaw: windowRaw)
        let surfaceArg = surface
            ?? (workspace == nil && windowRaw == nil
                ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
                : nil)
        var params: [String: Any] = [:]
        let winId = try normalizeWindowHandle(windowRaw, client: client)
        if let winId { params["window_id"] = winId }
        let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
        if let wsId { params["workspace_id"] = wsId }
        let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId)
        if let sfId { params["surface_id"] = sfId }
        return params
    }

    /// Implements `cmux send --submit` as two writes: a bracketed paste with
    /// submit disabled, followed by a named key event. The post-key probe is
    /// deliberately bounded so a stuck agent cannot leave the CLI hanging.
    func deliverSendSubmit(
        text: String,
        command: String,
        workspace: String?,
        surface: String?,
        windowRaw: String?,
        force: Bool,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        try Self.ensureTextFitsSocketRequest(text, command: command)
        let target = try terminalTargetParams(
            workspace: workspace,
            surface: surface,
            windowRaw: windowRaw,
            client: client
        )

        var state: [String: Any]?
        if !force {
            state = try ensureAgentPromptIsFree(
                for: .text,
                command: command,
                target: target,
                client: client
            )
        }
        var screen: String?
        if let payload = try? client.sendV2(method: "surface.read_text", params: target) {
            screen = payload["text"] as? String
        }
        if (state == nil || force), let screen,
           let fallback = Self.submitInputStateFromScreen(screen) {
            if !force {
                try throwIfAgentPromptBlocks(fallback, kind: .text, command: command, target: target)
            }
            if state == nil { state = fallback }
        }

        var pasteParams = target
        pasteParams["text"] = text
        pasteParams["submit_key"] = "none"
        _ = try client.sendV2(method: "terminal.paste", params: pasteParams)
        let agent = (state?["agent"] as? Bool) == true
        // Ghostty queues paste bytes before the next key event. Wait for the
        // composer to show the pasted block before submitting; an unchanged
        // empty snapshot can be the pre-paste state returned while the PTY is
        // still applying the bracketed paste.
        if agent {
            var pastedVisible = false
            for probe in 0..<4 {
                Thread.sleep(forTimeInterval: 0.1 * Double(probe + 1))
                let observed = try? client.sendV2(method: "surface.input_state", params: target)
                if let observed {
                    state = observed
                    let observedState = observed["state"] as? String
                    let slashPopup = (observed["slash_command_popup"] as? Bool) == true
                    if observedState == "dialog" && !slashPopup {
                        throw CLIError(message: String(
                            format: String(
                                localized: "cli.send.error.dialogOpen",
                                defaultValue: "%1$@: %2$@ is waiting on a question or dialog, so nothing was sent. Retry once it is answered, or pass --force to send anyway."
                            ),
                            command,
                            (target["surface_id"] as? String) ?? "?"
                        ))
                    }
                    if observedState == "draft" || observedState == "queued"
                        || (observed["queued"] as? Bool) == true || slashPopup {
                        pastedVisible = true
                        break
                    }
                }
                if let refreshed = try? client.sendV2(method: "surface.read_text", params: target),
                   let refreshedText = refreshed["text"] as? String {
                    screen = refreshedText
                    if Self.submitInputStateFromScreen(refreshedText)?["state"] as? String == "draft" {
                        pastedVisible = true
                        break
                    }
                }
            }
            if !pastedVisible {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.send.error.submitUnconfirmed",
                        defaultValue: "%@: %@; nothing was confirmed as submitted"
                    ),
                    command,
                    "the pasted message never became visible in the agent composer"
                ))
            }
        } else {
            Thread.sleep(forTimeInterval: 0.1)
        }

        let maxAttempts = 3
        var lastState = state
        var lastKey = "return"
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                let current = try? client.sendV2(method: "surface.input_state", params: target)
                if let current {
                    lastState = current
                    state = current
                }
                if let refreshed = try? client.sendV2(method: "surface.read_text", params: target),
                   let refreshedText = refreshed["text"] as? String {
                    screen = refreshedText
                }
                if sendStateIsConfirmed(lastState, screen: screen) {
                    return printSubmitResult(
                        status: sendSubmitStatus(lastState, key: lastKey),
                        payload: lastState ?? target,
                        jsonOutput: jsonOutput,
                        idFormat: idFormat
                    )
                }
                if let current = lastState,
                   (current["state"] as? String) == "dialog",
                   !((current["slash_command_popup"] as? Bool) == true || Self.screenShowsSlashPopup(screen)) {
                    return try sendSubmitUnconfirmed(
                        command: command,
                        target: target,
                        reason: "the target opened a dialog; retry was refused",
                        jsonOutput: jsonOutput,
                        idFormat: idFormat
                    )
                }
                let popupVisible = (currentPopupState(lastState) || Self.screenShowsSlashPopup(screen))
                guard !agent || popupVisible || Self.sendComposerMatches(screen, text: text, agentKind: state?["agent_kind"] as? String) else {
                    return try sendSubmitUnconfirmed(
                        command: command,
                        target: target,
                        reason: "the composer changed or could not be identified; retry was refused to preserve human input",
                        jsonOutput: jsonOutput,
                        idFormat: idFormat
                    )
                }
            }
            let busyCodex = agent
                && ((state?["busy"] as? Bool) == true || (state?["lifecycle"] as? String) == "running")
                && Self.stateOrScreenLooksLikeCodex(state, screen: screen)
            let key = busyCodex ? "tab" : "return"
            lastKey = key
            let slashPopupBeforeKey = (state?["slash_command_popup"] as? Bool) == true || Self.screenShowsSlashPopup(screen)
            var keyParams = target
            keyParams["key"] = key
            _ = try client.sendV2(method: "surface.send_key", params: keyParams)
            Thread.sleep(forTimeInterval: 0.1 * Double(attempt + 1))

            // Plain shells have no composer to inspect. The separate key was
            // accepted by the socket, which is the complete shell contract.
            if !agent {
                return printSubmitResult(
                    status: "submitted",
                    payload: target,
                    jsonOutput: jsonOutput,
                    idFormat: idFormat
                )
            }
            lastState = try? client.sendV2(method: "surface.input_state", params: target)
            if lastState == nil,
               let refreshed = try? client.sendV2(method: "surface.read_text", params: target),
               let refreshedText = refreshed["text"] as? String {
                screen = refreshedText
                lastState = Self.submitInputStateFromScreen(refreshedText)
            }
            if let lastState,
               (lastState["state"] as? String) == "dialog",
               !((lastState["slash_command_popup"] as? Bool) == true || Self.screenShowsSlashPopup(screen)) {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.send.error.dialogOpen",
                        defaultValue: "%1$@: %2$@ is waiting on a question or dialog, so nothing was sent. Retry once it is answered, or pass --force to send anyway."
                    ),
                    command,
                    (target["surface_id"] as? String) ?? (lastState["surface_id"] as? String) ?? "?"
                ))
            }
            let popupStillVisible = (lastState?["slash_command_popup"] as? Bool) == true
                || Self.screenShowsSlashPopup(screen)
            if let lastState,
                ((lastState["state"] as? String) == "empty"
                    || (lastState["state"] as? String) == "queued"
                    || (lastState["queued"] as? Bool) == true),
                !popupStillVisible && (!slashPopupBeforeKey || attempt > 0) {
                return printSubmitResult(
                    status: sendSubmitStatus(lastState, key: key),
                    payload: lastState,
                    jsonOutput: jsonOutput,
                    idFormat: idFormat
                )
            }
            if attempt + 1 < maxAttempts {
                continue
            }
        }

        Thread.sleep(forTimeInterval: 0.3)
        if let finalState = try? client.sendV2(method: "surface.input_state", params: target) {
            lastState = finalState
        }
        if let refreshed = try? client.sendV2(method: "surface.read_text", params: target),
           let refreshedText = refreshed["text"] as? String {
            screen = refreshedText
        }
        if sendStateIsConfirmed(lastState, screen: screen) {
            return printSubmitResult(
                status: sendSubmitStatus(lastState, key: lastKey),
                payload: lastState ?? target,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        }
        return try sendSubmitUnconfirmed(
            command: command,
            target: target,
            reason: "the submit key was sent but submission was not confirmed after bounded retries",
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }

    private func printSubmitResult(
        status: String,
        payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        var result = payload
        result["status"] = status
        result["submitted"] = status == "submitted"
        result["queued"] = status == "queued"
        printV2Payload(result, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: status)
    }

    private func sendSubmitUnconfirmed(
        command: String,
        target: [String: Any],
        reason: String,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var payload = target
        payload["status"] = "unconfirmed"
        payload["submitted"] = false
        payload["queued"] = false
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "unconfirmed")
        throw CLIError(message: String(
            format: String(
                localized: "cli.send.error.submitUnconfirmed",
                defaultValue: "%@: %@; text may already be submitted, do not paste it again without checking the target"
            ),
            command,
            reason
        ))
    }

    private func sendSubmitStatus(_ state: [String: Any]?, key: String = "return") -> String {
        if (state?["state"] as? String) == "queued" || (state?["queued"] as? Bool) == true || key == "tab" {
            return "queued"
        }
        let kind = (state?["agent_kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind?.isEmpty == false ? "submitted" : "sent"
    }

    private func currentPopupState(_ state: [String: Any]?) -> Bool {
        (state?["slash_command_popup"] as? Bool) == true
    }

    private func sendStateIsConfirmed(_ state: [String: Any]?, screen: String?) -> Bool {
        let observed = state ?? screen.flatMap(Self.submitInputStateFromScreen)
        guard let observed,
              (observed["agent"] as? Bool) == true,
              !((observed["slash_command_popup"] as? Bool) == true || Self.screenShowsSlashPopup(screen)) else {
            return false
        }
        return (observed["state"] as? String) == "empty"
            || (observed["state"] as? String) == "queued"
            || (observed["queued"] as? Bool) == true
    }

    private func throwIfAgentPromptBlocks(
        _ state: [String: Any],
        kind: TerminalInputWriteKind,
        command: String,
        target: [String: Any]
    ) throws {
        let dialog = state["state"] as? String == "dialog" && (state["agent"] as? Bool) == true
        let blocks: Bool
        switch kind {
        case .text:
            blocks = (state["blocks_typing"] as? Bool) == true
        case .key:
            blocks = dialog
        }
        guard blocks else { return }
        let surface = (target["surface_id"] as? String) ?? (state["surface_id"] as? String) ?? "?"
        if dialog {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.send.error.dialogOpen",
                    defaultValue: "%1$@: %2$@ is waiting on a question or dialog, so nothing was sent. Retry once it is answered, or pass --force to send anyway."
                ),
                command,
                surface
            ))
        }
        throw CLIError(message: String(
            format: String(
                localized: "cli.send.error.draftPresent",
                defaultValue: "%1$@: the agent prompt in %2$@ holds text someone is typing, so nothing was sent. Retry when the prompt is clear, or pass --force to send anyway."
            ),
            command,
            surface
        ))
    }

    private static func screenLooksLikeCodex(_ screen: String?) -> Bool {
        guard let screen else { return false }
        let branded = screen.lowercased().contains("openai codex")
            || screen.lowercased().contains("codex cli")
        guard branded else { return false }
        return screen.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("›") || trimmed.hasPrefix("> ")
        }
    }

    private static func stateOrScreenLooksLikeCodex(
        _ state: [String: Any]?,
        screen: String?
    ) -> Bool {
        if let kind = state?["agent_kind"] as? String,
           !kind.isEmpty {
            return kind.lowercased() == "codex"
        }
        return screenLooksLikeCodex(screen)
    }

    private static func screenShowsSlashPopup(_ screen: String?) -> Bool {
        guard let screen else { return false }
        return AgentPromptSubmissionSnapshot(screenText: screen).slashCommandPopup
    }

    private static func submitInputStateFromScreen(_ screen: String) -> [String: Any]? {
        let snapshot = AgentPromptSubmissionSnapshot(screenText: screen)
        let brandedAgent = screen.lowercased()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { row in
                row == "claude code"
                    || row.hasPrefix("openai codex")
                    || row == "codex cli"
                    || row == "codex"
            }
        var state: [String: Any] = [
            "state": "unknown",
            "agent": snapshot.agentKind != nil && brandedAgent,
            "busy": snapshot.busy,
            "queued": snapshot.queued,
            "slash_command_popup": snapshot.slashCommandPopup,
            "blocks_typing": snapshot.state.blocksTyping,
        ]
        switch snapshot.state {
        case .unknown:
            break
        case .empty:
            state["state"] = "empty"
        case .draft(let text):
            state["state"] = "draft"
            state["draft_length"] = text.count
            state["draft_text"] = text
        case .dialog:
            state["state"] = "dialog"
        }
        if let kind = snapshot.agentKind?.rawValue {
            state["agent_kind"] = kind
        }
        return state
    }

    private static func sendComposerMatches(
        _ screen: String?,
        text: String,
        agentKind: String?
    ) -> Bool {
        guard let screen,
              let observed = submitInputStateFromScreen(screen),
              let draft = observed["draft_text"] as? String else {
            return false
        }
        if let agentKind,
           let observedKind = observed["agent_kind"] as? String,
           !agentKind.isEmpty,
           observedKind != agentKind {
            return false
        }
        return normalizeComposerText(draft) == normalizeComposerText(text)
    }

    private static func normalizeComposerText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pasteSummary(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let summary = v2OKSummary(payload, idFormat: idFormat)
        guard (payload["delivery"] as? String) == "queued" else { return summary }
        let suffix = String(
            localized: "cli.send.queuedSuffix",
            defaultValue: "queued (terminal starting; input will be sent when its PTY is ready)"
        )
        return "\(summary) \(suffix)"
    }

    private static var pasteMissingTextMessage: String {
        String(
            localized: "cli.paste.error.missingText",
            defaultValue: "paste requires text as an argument or on stdin"
        )
    }

    private func pasteTextFromStandardInput() throws -> String {
        switch CLIStandardInputText.shared.read() {
        case .success(let text):
            return text
        case .failure(.interactive):
            // An interactive stdin with no text argument is almost always a
            // mistake; fail instead of silently waiting for EOF.
            throw CLIError(message: Self.pasteMissingTextMessage)
        case .failure(.invalidUTF8):
            throw CLIError(message: String(
                localized: "cli.paste.error.invalidUTF8",
                defaultValue: "paste: stdin is not valid UTF-8 text"
            ))
        case .failure(.tooLarge):
            throw Self.textTooLargeError(command: "paste")
        }
    }

    /// Text for `set-buffer` read from stdin, with set-buffer's own errors.
    func setBufferTextFromStandardInput() throws -> String {
        switch CLIStandardInputText.shared.read() {
        case .success(let text):
            return text
        case .failure(.interactive):
            throw CLIError(message: "set-buffer requires text")
        case .failure(.invalidUTF8):
            throw CLIError(message: String(
                localized: "cli.setBuffer.error.invalidUTF8",
                defaultValue: "set-buffer: stdin is not valid UTF-8 text"
            ))
        case .failure(.tooLarge):
            throw Self.textTooLargeError(command: "set-buffer")
        }
    }

    /// The text arguments of `set-buffer` after `--name` and a leading `--`,
    /// and whether they ask for stdin (none, or a lone `-`).
    func setBufferTextArguments(_ commandArgs: [String]) -> (name: String, textArgs: [String], readsStandardInput: Bool) {
        let (nameArg, rem0) = parseOption(commandArgs, name: "--name")
        let name = (nameArg?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? nameArg! : "default"
        let textArgs = Array(rem0.dropFirst(rem0.first == "--" ? 1 : 0))
        return (name, textArgs, textArgs.isEmpty || textArgs == ["-"])
    }

    /// Drains stdin for commands that take piped text, before the CLI opens
    /// and authenticates its socket. A slow producer (`slow-cmd | cmux paste`)
    /// would otherwise hold an idle connection open and can run past the
    /// socket's pre-authentication deadline. The text is cached for the
    /// command body. Argument errors surface here too, before any connection.
    func prepareStandardInputBeforeSocket(command: String, commandArgs: [String]) throws {
        switch command {
        case "paste":
            let parsed = try parsePasteCommandArguments(commandArgs)
            if parsed.text == nil {
                _ = try pasteTextFromStandardInput()
            }
        case "set-buffer":
            if setBufferTextArguments(commandArgs).readsStandardInput {
                _ = try setBufferTextFromStandardInput()
            }
        default:
            break
        }
    }

    /// The control socket buffers at most 16 MiB per request line
    /// (`ControlClientAsyncTransport.maximumBufferedBytes`). Keep the encoded
    /// text under 15 MiB so the rest of the request always fits.
    static let maximumEncodedTextBytes = 15 * 1024 * 1024

    /// Fails with a clear error when `text` would not fit in one socket
    /// request once JSON-escaped (control characters can grow sixfold).
    static func ensureTextFitsSocketRequest(_ text: String, command: String) throws {
        let rawBytes = text.utf8.count
        if rawBytes <= maximumEncodedTextBytes / 6 { return }
        guard rawBytes <= maximumEncodedTextBytes,
              let encoded = try? JSONSerialization.data(withJSONObject: [text], options: []),
              encoded.count <= maximumEncodedTextBytes else {
            throw textTooLargeError(command: command)
        }
    }

    static func textTooLargeError(command: String) -> CLIError {
        CLIError(message: String(
            format: String(
                localized: "cli.paste.error.tooLarge",
                defaultValue: "%@: text is too large; the limit is %@ MiB after JSON escaping"
            ),
            command,
            String(maximumEncodedTextBytes / (1024 * 1024))
        ))
    }

    // MARK: - Draft and dialog guard

    /// What a guarded command is about to write into a terminal.
    enum TerminalInputWriteKind {
        /// Typed or pasted text: refused over a draft or into a dialog.
        case text
        /// A single key: refused only into a dialog, because
        /// `cmux send "text"` followed by `cmux send-key enter` is the usual
        /// way to submit, and that leaves the sent text as a draft.
        case key
    }

    /// The guard for typed text: text that only presses Enter submits what
    /// is already in the prompt, like `cmux send-key enter`, so it is checked
    /// as a key.
    static func terminalInputWriteKind(forTypedText text: String) -> TerminalInputWriteKind {
        text.unicodeScalars.allSatisfy { $0 == "\r" || $0 == "\n" } ? .key : .text
    }

    /// Removes leading `--force` flags from a command's remaining arguments.
    /// Only flags before the text or key count, so `cmux send echo --force`
    /// still types `--force` as text.
    static func splitLeadingForceFlag(_ args: [String]) -> (force: Bool, rest: [String]) {
        var rest = args[...]
        var force = false
        while rest.first == "--force" {
            force = true
            rest = rest.dropFirst()
        }
        return (force, Array(rest))
    }

    /// Throws instead of letting `command` write into an agent prompt that
    /// holds a draft someone is typing, or into an open question or
    /// permission dialog. `target` carries the resolved `window_id`,
    /// `workspace_id` and `surface_id` of the write.
    ///
    /// An app that can't answer `surface.input_state` (an older build, or a
    /// remote relay that doesn't forward it) keeps the previous behavior.
    @discardableResult
    func ensureAgentPromptIsFree(
        for kind: TerminalInputWriteKind,
        command: String,
        target: [String: Any],
        client: SocketClient
    ) throws -> [String: Any]? {
        var params: [String: Any] = [:]
        for key in ["window_id", "workspace_id", "surface_id"] {
            if let value = target[key] { params[key] = value }
        }
        let state: [String: Any]
        do {
            state = try client.sendV2(method: "surface.input_state", params: params)
        } catch {
            return nil
        }
        try throwIfAgentPromptBlocks(state, kind: kind, command: command, target: target)
        return state
    }

    // MARK: - cmux send --paste

    /// Removes the leading `--paste` and `--force` flags from `cmux send`'s
    /// text arguments. Only flags before the text count, so
    /// `cmux send echo --paste` and `cmux send -- --paste` still type
    /// `--paste` as text, as before.
    static func splitSendPasteFlag(_ args: [String]) -> (usesPaste: Bool, submit: Bool, force: Bool, textArgs: [String]) {
        var rest = args[...]
        var usesPaste = false
        var submit = false
        var force = false
        while let flag = rest.first, flag == "--paste" || flag == "--submit" || flag == "--force" {
            if flag == "--paste" { usesPaste = true }
            if flag == "--submit" { submit = true }
            if flag == "--force" { force = true }
            rest = rest.dropFirst()
        }
        return (usesPaste, submit, force, Array(rest))
    }

    /// `cmux send` without `--paste` suggests the paste path when the text is
    /// more than this many UTF-8 bytes and has a line break. Both conditions
    /// are required so ordinary commands (short, or one long line) never see
    /// the hint.
    static let sendPasteHintMinimumUTF8Bytes = 4096

    /// Whether keystroke `send` text is large multi-line text: more than
    /// ``sendPasteHintMinimumUTF8Bytes`` UTF-8 bytes with at least one line
    /// break (a newline, or a `\n`/`\r` escape, both of which become Enter).
    static func sendTextWarrantsPasteHint(_ text: String) -> Bool {
        guard text.utf8.count > sendPasteHintMinimumUTF8Bytes else { return false }
        return text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    /// Prints a one-line hint on stderr after a keystroke `send` of large
    /// multi-line text. Stdout and the exit status are unaffected.
    static func printSendPasteHintIfNeeded(_ text: String) {
        guard sendTextWarrantsPasteHint(text) else { return }
        let hint = String(
            localized: "cli.send.hint.usePaste",
            defaultValue: "hint: each newline was typed as Enter; for large multi-line text use cmux send --paste or cmux paste to deliver it as one paste"
        )
        FileHandle.standardError.write(Data((hint + "\n").utf8))
    }

    static var sendHelp: String {
        String(localized: "cli.help.send", defaultValue: """
        Usage: cmux send [flags] [--] <text>

        Send text to a terminal surface as keystrokes. Escape sequences: \\n and \\r send Enter, \\t sends Tab.

        For large text (for example over 4 KB, or several lines going to an agent), use --paste or cmux paste. Keystrokes press Enter at every newline, which can submit each line on its own.

        With --paste, the text goes through the same paste path as cmux paste and Cmd+V, unchanged: escape sequences such as \\n are not interpreted, and control characters such as Esc and Ctrl-C are replaced with spaces. --paste must come before the text.

        If an agent prompt in the target holds text someone is typing, or a question or permission dialog is open, nothing is sent and the command fails. --force sends anyway.

        Flags:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Target surface (default: $CMUX_SURFACE_ID)
          --window <id|ref|index>      Window context for workspace/surface refs and indexes
          --paste                      Paste the text instead of typing it
          --submit                     Paste, then submit with a separate key event and verify delivery
          --force                      Send even over a draft or into an open dialog

        Example:
          cmux send "echo hello"
          cmux send --surface surface:2 "ls -la\\n"
          cmux send --paste --surface surface:2 "$(cat notes.md)"
        """)
    }

    static var pasteHelp: String {
        String(localized: "cli.help.paste", defaultValue: """
        Usage: cmux paste [flags] [--] [text | -]

        Paste text into a terminal surface through the same paste path as Cmd+V. If the running program has turned on bracketed paste, the text arrives as one paste and newlines stay inside it; otherwise each newline is sent as Enter. As with Cmd+V, control characters such as Esc, Backspace, Ctrl-C and Ctrl-U are replaced with spaces. Escape sequences such as \\n are not interpreted. With no text argument, or with - before --, the text is read from stdin. Text over 15 MiB after JSON escaping is rejected.

        If an agent prompt in the target holds text someone is typing, or a question or permission dialog is open, nothing is sent and the command fails. --force sends anyway.

        Flags:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Target surface (default: $CMUX_SURFACE_ID)
          --window <id|ref|index>      Window context for workspace/surface refs and indexes
          --submit                     Press the agent's submit key after the paste
          --force                      Send even over a draft or into an open dialog

        Example:
          git diff | cmux paste --surface surface:2
          cmux read-screen --surface surface:1 --lines 40 | cmux paste --surface surface:2
          cmux paste --surface surface:2 --submit "Review this change"
        """)
    }
}

/// Standard input read once per CLI process and cached, so a command can drain
/// it before connecting to the socket and use the same text afterwards.
final class CLIStandardInputText: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// Stdin is a terminal, so there is no piped text to read.
        case interactive
        case invalidUTF8
        case tooLarge
    }

    static let shared = CLIStandardInputText()

    private let lock = NSLock()
    private var cached: Result<String, Failure>?

    func read() -> Result<String, Failure> {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let result = Self.readStandardInput()
        cached = result
        return result
    }

    private static func readStandardInput() -> Result<String, Failure> {
        if isatty(STDIN_FILENO) == 1 { return .failure(.interactive) }
        // Stop reading past the socket limit instead of buffering an
        // unbounded producer; the command fails either way.
        let limit = CMUXCLI.maximumEncodedTextBytes
        var data = Data()
        let handle = FileHandle.standardInput
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > limit { return .failure(.tooLarge) }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.invalidUTF8)
        }
        return .success(text)
    }
}
