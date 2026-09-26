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
        try Self.ensureTextFitsSocketRequest(text, command: "paste")

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

    static var pasteHelp: String {
        String(localized: "cli.help.paste", defaultValue: """
        Usage: cmux paste [flags] [--] [text | -]

        Paste text into a terminal surface through the same paste path as Cmd+V. If the running program has turned on bracketed paste, the text arrives as one paste and newlines stay inside it; otherwise each newline is sent as Enter. As with Cmd+V, control characters such as Esc, Backspace, Ctrl-C and Ctrl-U are replaced with spaces. Escape sequences such as \\n are not interpreted. With no text argument, or with - before --, the text is read from stdin. Text over 15 MiB after JSON escaping is rejected.

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
