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
        let (timeoutOption, afterTimeout) = parseOption(remaining, name: "--timeout")
        remaining = afterTimeout
        let (workspaceOption, afterWorkspace) = parseOption(remaining, name: "--workspace")
        remaining = afterWorkspace
        if let stray = remaining.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            let prefix = String(
                localized: "cli.browser.repl.error.unknownOption",
                defaultValue: "browser repl does not support this option"
            )
            throw CLIError(message: "\(prefix): \(stray)")
        }

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
        let color = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        if let error = payload["error"] as? String {
            print(color ? "\u{1B}[31m\(error)\u{1B}[0m" : error)
            print(color ? "\u{1B}[31m[error | \(duration)ms]\u{1B}[0m" : "[error | \(duration)ms]")
        } else {
            print(color ? "\u{1B}[2m[ok | \(duration)ms]\u{1B}[0m" : "[ok | \(duration)ms]")
        }
        fflush(stdout)
        return ok
    }

    private static func readBrowserReplStandardInput() throws -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= maximumEncodedTextBytes else {
            throw CLIError(message: String(
                localized: "cli.browser.repl.error.inputTooLarge",
                defaultValue: "REPL input is too large"
            ))
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
        let usage = "repl [--session <name>] [--workspace <id|ref>] [--eval <code>|-] [--timeout <ms>] [<code>]"
        let description = String(
            localized: "cli.browser.help.replDescription",
            defaultValue: "Run Playwright-style JavaScript against this workspace's browser panes; see `browser repl guide`"
        )
        return "\(usage)\n              \(description)"
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
