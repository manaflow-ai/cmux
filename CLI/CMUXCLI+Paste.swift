import Darwin
import Foundation

extension CMUXCLI {
    /// Parsed `cmux paste` arguments: the target options stay raw so the shared
    /// handle normalizers resolve them exactly like `cmux send`.
    struct PasteCommandArguments: Equatable {
        var workspace: String?
        var surface: String?
        var window: String?
        var submit = false
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
            case "-":
                readsStandardInput = true
            default:
                // Everything here lands in an agent prompt, so a mistyped flag
                // or an option missing its value must fail rather than be
                // pasted. Text that starts with "--" goes after the terminator.
                if arg.hasPrefix("--") {
                    throw CLIError(message: String(
                        format: String(
                            localized: "cli.paste.error.unknownFlag",
                            defaultValue: "paste: unknown flag or missing value: %@ (put text that starts with -- after a -- separator)"
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

    /// `cmux paste`: deliver text to a terminal as one bracketed paste.
    ///
    /// Unlike `cmux send`, the text is passed through byte for byte: newlines
    /// stay inside the paste instead of pressing Enter, `\n`-style escapes are
    /// not interpreted, and the terminal receives it through the same paste path
    /// as Cmd+V (`terminal.paste`), so TUIs such as Claude Code and Codex see a
    /// single paste rather than a stream of keystrokes.
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
            text = try readPasteTextFromStandardInput()
        }
        guard !text.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.paste.error.missingText",
                defaultValue: "paste requires text as an argument or on stdin"
            ))
        }

        let windowRaw = parsed.window ?? windowOverride
        let workspaceArg = parsed.workspace
            ?? Self.callerWorkspaceForSurfaceHandle(parsed.surface, windowRaw: windowRaw)
        let surfaceArg = parsed.surface
            ?? (parsed.workspace == nil && windowRaw == nil
                ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
                : nil)

        var params: [String: Any] = [
            "text": text,
            // `return` lets the host pick the agent-aware submit key (for
            // example ctrl+enter for a multi-line Claude Code prompt).
            "submit_key": parsed.submit ? "return" : "none",
        ]
        let winId = try normalizeWindowHandle(windowRaw, client: client)
        if let winId { params["window_id"] = winId }
        let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
        if let wsId { params["workspace_id"] = wsId }
        let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId)
        if let sfId { params["surface_id"] = sfId }

        let payload = try client.sendV2(method: "terminal.paste", params: params)
        if parsed.submit, (payload["submitted"] as? Bool) != true {
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
        printV2Payload(
            payload,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: pasteSummary(payload, idFormat: idFormat)
        )
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

    private func readPasteTextFromStandardInput() throws -> String {
        // An interactive stdin with no text argument is almost always a
        // mistake; fail instead of silently waiting for EOF.
        if isatty(STDIN_FILENO) == 1 {
            throw CLIError(message: String(
                localized: "cli.paste.error.missingText",
                defaultValue: "paste requires text as an argument or on stdin"
            ))
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError(message: String(
                localized: "cli.paste.error.invalidUTF8",
                defaultValue: "paste: stdin is not valid UTF-8 text"
            ))
        }
        return text
    }

    static var pasteHelp: String {
        String(localized: "cli.help.paste", defaultValue: """
        Usage: cmux paste [flags] [--] [text | -]

        Paste text into a terminal surface as a single bracketed paste, the same way Cmd+V does. Text is sent exactly as given: newlines stay inside the paste instead of pressing Enter, and escape sequences such as \\n are not interpreted. With no text argument, or with -, the text is read from stdin.

        Flags:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Target surface (default: $CMUX_SURFACE_ID)
          --window <id|ref|index>      Window context for workspace/surface refs and indexes
          --submit                     Press the agent's submit key after the paste

        Example:
          git diff | cmux paste --surface surface:2
          cmux read-screen --surface surface:1 --lines 40 | cmux paste --surface surface:2
          cmux paste --surface surface:2 --submit "Review this change"
        """)
    }
}
