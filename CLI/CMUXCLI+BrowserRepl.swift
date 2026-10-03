import Darwin
import Foundation

extension CMUXCLI {
    /// `cmux browser repl`: evaluates Playwright-style JavaScript against cmux
    /// browser panes in a persistent JavaScriptCore session inside the app.
    func runBrowserRepl(_ arguments: [String], client: SocketClient, jsonOutput: Bool) throws {
        if let first = arguments.first?.lowercased() {
            switch first {
            case "guide":
                print(Self.browserReplGuideText())
                return
            case "list":
                let payload = try client.sendV2(method: "browser.repl.list", params: [:])
                if jsonOutput {
                    print(jsonString(payload))
                } else {
                    for session in payload["sessions"] as? [[String: Any]] ?? [] {
                        let name = session["session"] as? String ?? ""
                        let idle = session["idle_seconds"] as? Int ?? 0
                        let cwd = session["cwd"] as? String ?? ""
                        print("\(name)\t\(idle)s\t\(cwd)")
                    }
                }
                return
            case "mcp":
                try runBrowserReplMCP(Array(arguments.dropFirst()), client: client)
                return
            case "reset":
                let (sessionOption, rest) = parseOption(Array(arguments.dropFirst()), name: "--session")
                guard let session = sessionOption ?? rest.first, !session.isEmpty else {
                    throw CLIError(message: String(
                        localized: "cli.browser.repl.error.sessionRequired",
                        defaultValue: "A session name is required"
                    ))
                }
                let payload = try client.sendV2(method: "browser.repl.reset", params: ["session": session])
                print(jsonOutput ? jsonString(payload) : "OK")
                return
            default:
                break
            }
        }

        var remaining = arguments
        let (sessionOption, afterSession) = parseOption(remaining, name: "--session")
        remaining = afterSession
        let (evalOption, afterEval) = parseOption(remaining, name: "--eval")
        remaining = afterEval
        let (baseParams, timeoutMilliseconds, afterBase) = try browserReplBaseParams(remaining, client: client)
        remaining = afterBase
        if let stray = remaining.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            let prefix = String(
                localized: "cli.browser.repl.error.unknownOption",
                defaultValue: "browser repl does not support this option"
            )
            throw CLIError(message: "\(prefix): \(stray)")
        }

        let positional = remaining.filter { $0 != "--" }
        let code: String?
        if let evalOption {
            code = evalOption == "-" ? try Self.readBrowserReplStandardInput() : evalOption
        } else if !positional.isEmpty {
            code = positional.joined(separator: " ")
        } else if isatty(STDIN_FILENO) == 0 {
            code = try Self.readBrowserReplStandardInput()
        } else {
            code = nil
        }

        if let code {
            var params = baseParams
            params["code"] = code
            if let sessionOption { params["session"] = sessionOption }
            let ok = try evaluateBrowserRepl(params: params, client: client, jsonOutput: jsonOutput, timeoutMilliseconds: timeoutMilliseconds)
            if !ok {
                // The error is already printed; only the exit status remains.
                fflush(stdout)
                exit(1)
            }
            return
        }

        // Interactive: one line per cell in a session that lives until EOF.
        let session = sessionOption ?? "cli-\(getpid())"
        defer {
            if sessionOption == nil {
                _ = try? client.sendV2(method: "browser.repl.reset", params: ["session": session])
            }
        }
        while true {
            FileHandle.standardError.write(Data("> ".utf8))
            guard let line = readLine(strippingNewline: true) else { break }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var params = baseParams
            params["code"] = line
            params["session"] = session
            _ = try evaluateBrowserRepl(params: params, client: client, jsonOutput: jsonOutput, timeoutMilliseconds: timeoutMilliseconds)
        }
    }

    /// Parses `--timeout`, `--workspace` and `--max-output` into the params
    /// every `browser.repl.eval` call carries.
    /// - Returns: The params, the timeout in milliseconds and the arguments left.
    private func browserReplBaseParams(
        _ arguments: [String],
        client: SocketClient
    ) throws -> ([String: Any], Int, [String]) {
        var remaining = arguments
        let (timeoutOption, afterTimeout) = parseOption(remaining, name: "--timeout")
        remaining = afterTimeout
        let (workspaceOption, afterWorkspace) = parseOption(remaining, name: "--workspace")
        remaining = afterWorkspace
        let (maxOutputOption, afterMaxOutput) = parseOption(remaining, name: "--max-output")
        remaining = afterMaxOutput
        var timeoutMilliseconds = 120_000
        if let timeoutOption {
            guard let value = Int(timeoutOption), value > 0 else {
                throw CLIError(message: String(
                    localized: "cli.browser.repl.error.timeout",
                    defaultValue: "--timeout must be a positive number of milliseconds"
                ))
            }
            timeoutMilliseconds = value
        }

        var baseParams: [String: Any] = [
            "cwd": FileManager.default.currentDirectoryPath,
            "timeout_ms": timeoutMilliseconds,
        ]
        // Characters one call prints before the rest goes to a file; 0 for
        // no limit. The runtime's default applies without the option.
        if let maxOutputOption {
            guard let value = Int(maxOutputOption), value >= 0 else {
                throw CLIError(message: String(
                    localized: "cli.browser.repl.error.maxOutput",
                    defaultValue: "--max-output must be a number of characters, or 0 for no limit"
                ))
            }
            baseParams["max_output"] = value
        }
        // `--workspace` must exist. `CMUX_WORKSPACE_ID` is only a hint: it can
        // come from another cmux instance, so the app falls back to the
        // focused workspace when it does not know the id.
        if let workspaceOption, !workspaceOption.isEmpty {
            if let workspace = try normalizeWorkspaceHandle(workspaceOption, client: client) {
                baseParams["workspace_id"] = workspace
            }
        } else if let caller = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            UUID(uuidString: caller) != nil {
            baseParams["caller_workspace_id"] = caller
        }

        return (baseParams, timeoutMilliseconds, remaining)
    }

    /// `cmux browser repl mcp`: a Model Context Protocol server on stdio whose
    /// tools run in one REPL session through `browser.repl.eval` and
    /// `browser.repl.reset`, the socket methods the other subcommands use.
    private func runBrowserReplMCP(_ arguments: [String], client: SocketClient) throws {
        let (sessionOption, afterSession) = parseOption(arguments, name: "--session")
        let (sharedParams, timeoutMilliseconds, remaining) = try browserReplBaseParams(afterSession, client: client)
        var baseParams = sharedParams
        // MCP hosts often start servers in `/` or the home directory, which
        // the app refuses as an fs root and the agent cannot change. Send no
        // cwd then, so the session gets a temporary directory of its own.
        if let cwd = baseParams["cwd"] as? String, Self.browserReplCwdIsTooBroad(cwd) {
            baseParams.removeValue(forKey: "cwd")
        }
        if let stray = remaining.first {
            let prefix = String(
                localized: "cli.browser.repl.error.unknownOption",
                defaultValue: "browser repl does not support this option"
            )
            throw CLIError(message: "\(prefix): \(stray)")
        }
        // Without --session each server process gets its own session, so two
        // MCP clients never share variables and tabs by accident; a named
        // session is how clients share one on purpose.
        let namedSession = sessionOption.flatMap { $0.isEmpty ? nil : $0 }
        let session = namedSession
            ?? "mcp-\(getpid())-\(String(UInt32.random(in: .min ... .max), radix: 36))"
        let responseTimeout = TimeInterval(timeoutMilliseconds) / 1000 + 15
        let evaluate = { (code: String, maxOutput: Int?) throws -> [String: Any] in
            var params = baseParams
            params["code"] = code
            params["session"] = session
            if let maxOutput { params["max_output"] = maxOutput }
            return try client.sendV2(method: "browser.repl.eval", params: params, responseTimeout: responseTimeout)
        }
        let server = BrowserReplMCPServer(version: resolvedVersionInfo()["CFBundleShortVersionString"] ?? "dev") { name, arguments in
            switch name {
            case "reset":
                let payload = try client.sendV2(method: "browser.repl.reset", params: ["session": session])
                let existed = payload["existed"] as? Bool ?? false
                return .text(existed ? "Session \(session) reset" : "Session \(session) had no state")
            case "screenshot":
                let marker = "cmux-mcp-image:"
                let code = BrowserReplMCPServer.screenshotCode(arguments, marker: marker)
                let payload = try evaluate(code, 0)
                let lines = (payload["output"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                if let error = payload["error"] as? String {
                    return BrowserReplMCPServer.ToolResult(content: [["type": "text", "text": (lines + [error]).joined(separator: "\n")]], isError: true)
                }
                guard let line = lines.last(where: { $0.hasPrefix(marker) }) else {
                    return BrowserReplMCPServer.ToolResult(content: [["type": "text", "text": lines.joined(separator: "\n")]], isError: true)
                }
                return BrowserReplMCPServer.ToolResult(
                    content: [["type": "image", "data": String(line.dropFirst(marker.count)), "mimeType": "image/png"]],
                    isError: false
                )
            default:
                guard let code = BrowserReplMCPServer.code(forTool: name, arguments: arguments) else {
                    throw BrowserReplMCPServer.Failure.unknownTool(name)
                }
                return BrowserReplMCPServer.result(ofEval: try evaluate(code, nil))
            }
        }
        while let line = readLine(strippingNewline: true) {
            guard let reply = server.handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
        // No other client can name this server's own session, so its tabs
        // and variables end with the server instead of idling for 30 minutes.
        if namedSession == nil {
            _ = try? client.sendV2(method: "browser.repl.reset", params: ["session": session])
        }
    }

    /// Whether the app refuses `path` as a REPL fs root: `/`, the home
    /// directory or a directory containing it (`BrowserReplFileSandbox.rootRejection`).
    private static func browserReplCwdIsTooBroad(_ path: String) -> Bool {
        let canonical = (path as NSString).resolvingSymlinksInPath
        let home = (NSHomeDirectory() as NSString).resolvingSymlinksInPath
        return canonical == "/" || canonical == home || home.hasPrefix(canonical + "/")
    }

    /// Sends one cell and prints its output, then `[ok | Nms]` or `[error | Nms]`.
    /// - Returns: Whether the cell finished without an uncaught error.
    private func evaluateBrowserRepl(
        params: [String: Any],
        client: SocketClient,
        jsonOutput: Bool,
        timeoutMilliseconds: Int
    ) throws -> Bool {
        let responseTimeout = TimeInterval(timeoutMilliseconds) / 1000 + 15
        let payload = try client.sendV2(method: "browser.repl.eval", params: params, responseTimeout: responseTimeout)
        let ok = payload["ok"] as? Bool ?? false
        if jsonOutput {
            print(jsonString(payload))
            return ok
        }
        for line in payload["output"] as? [[String: Any]] ?? [] {
            print(line["text"] as? String ?? "")
        }
        let duration = payload["duration_ms"] as? Int ?? 0
        let color = ProcessInfo.processInfo.environment["NO_COLOR"] == nil && isatty(STDOUT_FILENO) != 0
        if let error = payload["error"] as? String {
            print(color ? "\u{1B}[31m\(error)\u{1B}[0m" : error)
            print(color ? "\u{1B}[31m[error | \(duration)ms]\u{1B}[0m" : "[error | \(duration)ms]")
        } else {
            print(color ? "\u{1B}[2m[ok | \(duration)ms]\u{1B}[0m" : "[ok | \(duration)ms]")
        }
        fflush(stdout)
        return ok
    }

    /// Reads stdin in chunks and stops as soon as it passes
    /// `maximumEncodedTextBytes`, so an endless stream is refused instead of
    /// being buffered whole.
    private static func readBrowserReplStandardInput() throws -> String {
        var data = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 1 << 20), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumEncodedTextBytes else {
                throw CLIError(message: String(
                    localized: "cli.browser.repl.error.inputTooLarge",
                    defaultValue: "REPL input is too large"
                ))
            }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError(message: String(
                localized: "cli.browser.repl.error.inputEncoding",
                defaultValue: "REPL input is not valid UTF-8"
            ))
        }
        return text
    }

    /// Help line for `cmux browser --help`.
    static var browserReplHelp: String {
        let usage = "repl [--session <name>] [--workspace <id|ref>] [--eval <code>|-] [--timeout <ms>] [--max-output <chars>] [<code>]"
        let description = String(
            localized: "cli.browser.help.replDescription",
            defaultValue: "Run Playwright-style JavaScript against this workspace's browser panes; see `browser repl guide`"
        )
        let mcpUsage = "repl mcp [--session <name>] [--workspace <id|ref>] [--timeout <ms>]"
        let mcpDescription = String(
            localized: "cli.browser.help.replMCPDescription",
            defaultValue: "Serve the REPL as an MCP server on stdio (tools: eval, snapshot, screenshot, tabs, reset; its own session unless --session names one)"
        )
        return "\(usage)\n              \(description)\n  \(mcpUsage)\n              \(mcpDescription)"
    }

    /// The guide shipped with the runtime (`browser-repl/guide.md` in the
    /// enclosing app, or `CMUX_BROWSER_REPL_RUNTIME_DIR`), else the built-in text.
    static func browserReplGuideText() -> String {
        var directories: [URL] = []
        if let override = ProcessInfo.processInfo.environment["CMUX_BROWSER_REPL_RUNTIME_DIR"], !override.isEmpty {
            directories.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let app = CLIExecutableLocator.enclosingAppBundle(), let resources = app.resourceURL {
            directories.append(resources.appendingPathComponent("browser-repl", isDirectory: true))
        }
        for directory in directories {
            let url = directory.appendingPathComponent("guide.md")
            if let text = try? String(contentsOf: url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.hasSuffix("\n") ? String(text.dropLast()) : text
            }
        }
        return browserReplGuide
    }

    /// Built-in agent-facing guide, used when the runtime ships no `guide.md`.
    static let browserReplGuide = """
    # `cmux browser repl`

    Run JavaScript in a persistent, sandboxed JavaScriptCore session that
    drives the browser panes of your cmux workspace. The API is Playwright:
    `page`, locators, `keyboard`, `mouse`, events and waits behave as in
    Playwright. Input is native: pages see trusted events.

    ## Usage

        cmux browser repl 'await page.goto("https://example.com"); snapshot()'
        cmux browser repl --eval - < script.js
        cmux browser repl --session work --eval 'const s1 = await snapshot()'
        cmux browser repl list | reset <session> | guide

    Without `--session` each call is one-shot: its tabs close at the end
    unless `page.keep()` was called. With `--session NAME`, top-level
    `const`/`let` bindings and tabs persist across calls. Idle sessions close
    after 30 minutes. The session binds to your cmux workspace, or to the
    focused workspace when you run outside cmux.

    ## Environment

    - ES2023+ JavaScript with top-level await.
    - 120 second timeout per call (`--timeout <ms>` to change it).
    - A call prints at most 25,000 characters (`--max-output <chars>`, 0 for
      no limit); the rest of its output goes to a file whose path prints.
      A printed snapshot is at most 20,000 characters; `.tree` is complete.
    - The last expression's value prints; `console.log()` prints too. The call
      ends with `[ok | Nms]`, or the uncaught error and `[error | Nms]` (exit
      status 1).
    - `fs`, `path`, `os`, `Buffer`: files are limited to the directory you ran
      the command in and the system temp directory.
    - `fetch(url)` sends the current tab's cookies.

    ## Globals

    - `page`: the current tab, a Playwright `Page`.
    - `tabs`: `list()`, `open(url, { background })`, `current()`, `use(tab)`,
      `get(id)`. `tabs.open()` never steals focus.
    - `snapshot(target?, options?)`: accessibility tree with refs such as
      `e12` or `f1e3` (frames). Pass refs to `page.locator("e12")`.
    - `screenshot(target?, { annotate: true })`: PNG, optionally with refs drawn.
    - `sleep(ms)`, `display(value)`, `session.name(label)`.

    ## Working

    - Read with `snapshot()` first; printing a later snapshot shows the diff
      when that is shorter. Never guess refs, selectors or URLs.
    - Prefer locator actions with refs over `page.evaluate()`.
    - Dialogs and file choosers stay open until answered:
      `page.dialog()?.accept()`, `page.fileChooser()?.setFiles(paths)`.
    - Treat an action as unconfirmed until a fresh snapshot shows its effect.
    """
}

/// JSON-RPC 2.0 handling for `cmux browser repl mcp` (Model Context Protocol,
/// newline-delimited messages on stdio). Tool calls go to `callTool`; this
/// type only speaks the protocol, so it is testable without a socket.
struct BrowserReplMCPServer {
    struct ToolResult {
        var content: [[String: Any]]
        var isError: Bool

        static func text(_ text: String, isError: Bool = false) -> ToolResult {
            ToolResult(content: [["type": "text", "text": text]], isError: isError)
        }
    }

    enum Failure: Error {
        case unknownTool(String)
    }

    /// Newest first; `initialize` echoes the client's version when listed.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let version: String
    let callTool: (String, [String: Any]) throws -> ToolResult

    init(version: String, callTool: @escaping (String, [String: Any]) throws -> ToolResult) {
        self.version = version
        self.callTool = callTool
    }

    static var tools: [[String: Any]] {
        [
            [
                "name": "eval",
                "description": "Run JavaScript in the cmux browser REPL session (Playwright API: page, tabs, snapshot, screenshot, locators; top-level await; const/let persist across calls). Returns what the code printed and the last expression's value. Run `session.guide()` for the full guide.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["code": ["type": "string", "description": "JavaScript to evaluate"]],
                    "required": ["code"],
                ] as [String: Any],
            ],
            [
                "name": "snapshot",
                "description": "Accessibility snapshot of the current tab with refs (e12, f1e3) usable as locators in eval. Prints the diff against the previous snapshot when that is shorter.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "description": "A ref or selector to scope the snapshot to"],
                        "interactive": ["type": "boolean", "description": "Only interactive elements and the page outline"],
                        "viewport": ["type": "boolean", "description": "Only elements in the viewport"],
                    ],
                ] as [String: Any],
            ],
            [
                "name": "screenshot",
                "description": "PNG of the current tab's viewport, the full page, or one element.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "description": "A ref or selector to capture"],
                        "fullPage": ["type": "boolean", "description": "Capture the whole page"],
                    ],
                ] as [String: Any],
            ],
            [
                "name": "tabs",
                "description": "The session's tabs: id, title, URL and which one is current.",
                "inputSchema": ["type": "object", "properties": [String: Any]()] as [String: Any],
            ],
            [
                "name": "reset",
                "description": "End the REPL session: close its tabs and forget its variables.",
                "inputSchema": ["type": "object", "properties": [String: Any]()] as [String: Any],
            ],
        ]
    }

    /// A JavaScript string literal for `text`.
    static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// REPL code for the tools that are one evaluation.
    static func code(forTool name: String, arguments: [String: Any]) -> String? {
        switch name {
        case "eval":
            return arguments["code"] as? String
        case "snapshot":
            let target = (arguments["target"] as? String).map(literal) ?? "undefined"
            let interactive = arguments["interactive"] as? Bool ?? false
            let viewport = arguments["viewport"] as? Bool ?? false
            return "await snapshot(\(target), { interactive: \(interactive), viewport: \(viewport) })"
        case "tabs":
            return "await tabs.list()"
        default:
            return nil
        }
    }

    /// REPL code that prints the screenshot as `marker` + base64 on one line.
    static func screenshotCode(_ arguments: [String: Any], marker: String) -> String {
        let fullPage = arguments["fullPage"] as? Bool ?? false
        let capture: String
        if let target = arguments["target"] as? String, !target.isEmpty {
            capture = "await page.locator(\(literal(target))).screenshot()"
        } else {
            capture = "await page.screenshot({ fullPage: \(fullPage) })"
        }
        return "console.log(\(literal(marker)) + (\(capture)).toString(\"base64\")); undefined"
    }

    /// A `browser.repl.eval` result as tool content: the printed lines, then
    /// the uncaught error, if any, as an error result.
    static func result(ofEval payload: [String: Any]) -> ToolResult {
        var lines = (payload["output"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let duration = payload["duration_ms"] as? Int ?? 0
        if let error = payload["error"] as? String {
            lines.append(error)
            lines.append("[error | \(duration)ms]")
            return .text(lines.joined(separator: "\n"), isError: true)
        }
        lines.append("[ok | \(duration)ms]")
        return .text(lines.joined(separator: "\n"))
    }

    /// Handles one line; returns the reply line, or nil for a notification.
    func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: []),
              let message = object as? [String: Any] else {
            return Self.encode(Self.error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        return handle(message).map(Self.encode)
    }

    /// Handles one message; returns the response, or nil for a notification
    /// or a response from the client.
    func handle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            guard let id else { return nil }
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.error(id: id, code: -32600, message: "Invalid Request")
        }
        guard let id, !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            return Self.reply(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "cmux-browser-repl", "version": self.version],
                "instructions": "Drive cmux browser tabs with Playwright-style JavaScript through the eval tool; read pages with snapshot and act on its refs.",
            ])
        case "ping":
            return Self.reply(id: id, result: [:])
        case "tools/list":
            return Self.reply(id: id, result: ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.error(id: id, code: -32602, message: "tools/call needs a tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard Self.tools.contains(where: { $0["name"] as? String == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            if name == "eval", arguments["code"] as? String == nil {
                return Self.error(id: id, code: -32602, message: "eval needs code, a string")
            }
            let result: ToolResult
            do {
                result = try callTool(name, arguments)
            } catch let failure as CLIError {
                result = .text(failure.message, isError: true)
            } catch {
                result = .text(String(describing: error), isError: true)
            }
            return Self.reply(id: id, result: ["content": result.content, "isError": result.isError])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func reply(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]]
    }

    private static func encode(_ message: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
