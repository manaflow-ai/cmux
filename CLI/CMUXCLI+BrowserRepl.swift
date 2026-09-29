import Darwin
import Foundation

extension CMUXCLI {
    /// `cmux browser repl`: evaluates Playwright-style JavaScript against cmux
    /// browser panes in a persistent JavaScriptCore session inside the app.
    func runBrowserRepl(_ arguments: [String], client: SocketClient, jsonOutput: Bool) throws {
        if let first = arguments.first?.lowercased() {
            switch first {
            case "guide":
                print(Self.browserReplGuide)
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
        let (dialectOption, afterDialect) = parseOption(remaining, name: "--dialect")
        remaining = afterDialect
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

        let dialect = (dialectOption ?? "aside").lowercased()
        guard dialect == "aside" || dialect == "chatgpt" else {
            throw CLIError(message: String(
                localized: "cli.browser.repl.error.dialect",
                defaultValue: "Unknown dialect; use aside or chatgpt"
            ))
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
            "dialect": dialect,
            "cwd": FileManager.default.currentDirectoryPath,
            "timeout_ms": timeoutMilliseconds,
        ]
        let workspaceRaw = workspaceOption ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        if let workspaceRaw, !workspaceRaw.isEmpty,
           let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
            baseParams["workspace_id"] = workspace
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
                // The error is already printed, Aside style; only the status remains.
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

    /// Sends one cell and prints its output the way `aside repl` does.
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
        let usage = "repl [--dialect aside|chatgpt] [--session <name>] [--eval <code>|-] [--timeout <ms>] [<code>]"
        let description = String(
            localized: "cli.browser.help.replDescription",
            defaultValue: "Run Playwright-style JavaScript against this workspace's browser panes; see `browser repl guide`"
        )
        return "\(usage)\n              \(description)"
    }

    /// Agent-facing guide, adapted from `aside guide repl`.
    static let browserReplGuide = """
    # `cmux browser repl`

    Run Playwright-style JavaScript in a persistent, sandboxed JavaScriptCore
    session that drives the browser panes of your cmux workspace. Input is
    native: pages see trusted mouse, keyboard, drag and wheel events.

    ## Usage

        cmux browser repl 'console.log(await listBrowserTabs())'
        cmux browser repl --eval - < script.js
        cmux browser repl --session work --eval 'const s1 = await snapshot(page)'
        cmux browser repl --dialect chatgpt --eval 'const tab = await agent.browsers.get("cmux")'
        cmux browser repl list | reset <session> | guide

    Without `--session` each call is one-shot: its session, tabs attachments
    and bindings are gone afterwards. With `--session NAME`, top-level
    `const`/`let` bindings persist across calls, so use fresh names
    (`s1`, `s2`, ...). Idle sessions close after 30 minutes.

    ## Environment

    - ES2023+ JavaScript (async/await). No `import` or `require`.
    - 120 second timeout per call (`--timeout <ms>` to change it).
    - `console.log()` is how you see values; the call ends with `[ok | Nms]`
      or the uncaught error and `[error | Nms]` (exit status 1).
    - `fs`, `path`, `Buffer`, `sleep`, `display`, `pwd`: `fs` is rooted at the
      directory you ran the command in; save artifacts under `./artifacts/`.
    - `fetch(url)` sends the attached tab's cookies. Use it only for safe
      same-origin or trusted direct-download GET/HEAD requests.

    ## Dialects

    `aside` (default) matches `aside repl`: `page`, `tabs`,
    `listBrowserTabs()`, `attachBrowserTab(targetId)`,
    `attachActiveBrowserTab()`, `getTabByTargetId(targetId)`, `openTab(url)`,
    `closeTab(tab)`, `snapshot(page, options?)`, `annotatedScreenshot(page)`.

    `chatgpt` matches ChatGPT for Chrome's runtime: `agent.browsers`,
    `Browser`, `Tab`, `tab.ax`, `tab.playwright`, `tab.cua`, `tab.dom_cua`,
    `tab.clipboard`, `tab.dev`, `tab.content`. Raw CDP and request
    interception are unavailable on WebKit panes.

    ## Tabs

    A session starts neutral: do not assume `page` is the pane you are
    looking at. List tabs first, then attach:

        const open1 = await listBrowserTabs();
        console.log(open1.map((t) => ({ targetId: t.targetId, active: t.active, title: t.title, url: t.url })));

    Tabs are the browser surfaces of your workspace; `openTab(url)` adds a
    background surface without taking focus. Use `openTab()`/`closeTab()`
    for tab management, not `page.context().newPage()` or `page.close()`.

    ## Reading pages

    Always read with `snapshot()` first:

        const s1 = await snapshot(page, { interactive: true });
        console.log(s1.tree);

    - The tree has ARIA roles and ref ids such as `e12` or `f1e3` (frames).
      Pass refs straight to `page.locator('e12')`; they are not DOM ids.
    - Each snapshot invalidates earlier refs. After an action, print `diff`
      of a new snapshot instead of the whole tree.
    - Escalate: `snapshot(page, { interactive: true })`, `snapshot(page)`,
      then `annotatedScreenshot(page)` or `page.screenshot()`.
    - Never guess refs, selectors or URLs; never truncate a snapshot.

    ## Acting

    - Prefer locator actions with refs over `page.evaluate()`.
    - `openTab()` and `click()` already wait for the page; add `sleep()` only
      when a fresh snapshot shows the page still changing.
    - Dialogs arrive as `page.on("dialog")`; unhandled dialogs are dismissed.
    - File inputs: `locator.setInputFiles()` or `page.waitForEvent("filechooser")`.
    - Downloads: `const d = await page.waitForEvent("download")`, then
      `await d.path()` is readable with `fs` in the same session.
    - Treat an action as unconfirmed until a fresh snapshot shows its effect.
    """
}
