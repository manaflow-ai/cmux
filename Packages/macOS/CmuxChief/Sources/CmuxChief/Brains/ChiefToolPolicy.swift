import Foundation

/// What a Chief may do without asking, and how its tool calls read in Home.
///
/// Auto-allowed without an approval card:
///
/// - Claude Code's read-only tools: `Read`, `Glob`, `Grep`, `WebSearch`,
///   `WebFetch`, `ToolSearch`.
/// - A shell command line whose every simple command is allowed, joined by
///   `|`, `&&`, `||`, `;` or newlines (see ``ChiefShellLexer``). Redirects
///   are limited to `2>&1` and `>/dev/null`; substitution, subshells,
///   backticks, `<`, background `&` and `$` expansion outside single quotes
///   ask. The allowed simple commands:
///   - `cmux …`, except a call naming a destructive verb (closing,
///     removing, killing, quitting, clearing, publishing, `sudo`, `rpc`,
///     `--force` and the like; see ``cmuxApprovalWords``).
///   - Read-only tools: `ls`, `pwd`, `cat`, `head`, `tail`, `wc`, `which`,
///     `date`, `jq`, `grep`, `cut`, `tr`, `column`; `rg` without `--pre`;
///     `sort` without `-o`; `uniq` with at most one file; `awk` without
///     `system`, pipes, redirection, `getline` or program files; `sed -n`
///     whose script only prints (`p`, `=`, `l`, `q`, `d`, `n`, `s///` with
///     `gpiI` flags).
///   - Read-only `git` (`status`, `log`, `diff`, `show`, listing `branch`,
///     …) and `gh` (`pr view|list|diff|checks|status`, `issue view|list`,
///     …).
///
/// Everything else (edits, writes, other commands) asks the user. The same
/// check covers Codex's approval requests after unwrapping `zsh -lc '…'`.
enum ChiefToolPolicy {
    /// The options of every approval card, allow first.
    static let approvalOptions = ["Allow", "Deny"]

    /// Whether a choice from ``approvalOptions`` grants the call.
    static func isAllow(_ choice: String) -> Bool {
        choice.caseInsensitiveCompare("Allow") == .orderedSame
    }

    /// Whether an approval option refuses (Stop settles a waiting card with it).
    static func isRefusal(_ choice: String) -> Bool {
        ["deny", "decline", "reject", "no", "cancel"].contains(choice.lowercased())
    }

    private static let readOnlyTools: Set<String> = ["Read", "Glob", "Grep", "WebSearch", "WebFetch", "ToolSearch"]

    /// Whether Claude Code's `tool` with `input` runs without asking.
    ///
    /// - Parameters:
    ///   - tool: The tool name from the permission request.
    ///   - input: The tool's input.
    static func autoAllowsClaudeTool(_ tool: String, input: ChiefJSON) -> Bool {
        if readOnlyTools.contains(tool) { return true }
        if tool == "Bash", let command = input["command"]?.string { return autoAllowsCommand(command) }
        return false
    }

    /// Whether a shell command line runs without asking.
    ///
    /// - Parameter command: The command line, possibly wrapped in `sh -lc '…'`.
    static func autoAllowsCommand(_ command: String) -> Bool {
        let line = unwrapShell(command)
        guard let stages = ChiefShellLexer.stages(of: line), !stages.isEmpty else { return false }
        for stage in stages {
            // `$HOME`-style expansion could smuggle flags past the checks.
            if stage.contains(where: \.expands) { return false }
            let words = stage.map(\.text)
            // The user's "Always Allow" rules (an approval card's menu) cover their program and subcommand.
            guard autoAllowsSimpleCommand(words) || ChiefAllowRules.shared.allows(words) else { return false }
        }
        return true
    }

    /// Words that make a `cmux` call ask first, wherever they appear in it
    /// (lowercased): verbs that close, remove, kill, quit, wipe, publish or
    /// escalate, and flags that override a safety check.
    static let cmuxApprovalWords: Set<String> = [
        "close", "rm", "remove", "delete", "destroy", "kill", "quit", "restart", "relaunch", "reset",
        "clear", "clear-history", "cleanup", "ssh-session-cleanup", "uninstall", "logout",
        "sudo", "rpc", "pipe-pane", "respawn-pane", "set-hook",
        "publish", "access", "grant", "ungrant", "upload", "feedback", "promote-template",
        "--force", "--yes",
    ]
    private static let cmuxApprovalPrefixes = ["close-", "kill-"]

    private static let plainReadOnlyPrograms: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "which", "jq", "grep", "cut", "tr", "column",
    ]

    /// Whether one simple command (quotes removed) runs without asking.
    static func autoAllowsSimpleCommand(_ words: [String]) -> Bool {
        // A bare program name only: `/tmp/x/cmux` is not the cmux CLI.
        guard let program = words.first else { return false }
        let args = Array(words.dropFirst())
        switch program {
        case "cmux":
            return !args.contains { word in
                let lower = word.lowercased()
                return cmuxApprovalWords.contains(lower) || cmuxApprovalPrefixes.contains { lower.hasPrefix($0) }
            }
        case _ where plainReadOnlyPrograms.contains(program):
            return true
        case "date":
            return !args.contains { $0 == "-s" || $0.hasPrefix("--set") }
        case "rg":
            return !args.contains { $0.hasPrefix("--pre") }
        case "sort":
            return !args.contains { $0.hasPrefix("--output") || $0.hasPrefix("--compress-program")
                || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("o")) }
        case "uniq":
            // `uniq in out` writes `out`.
            return args.filter { !$0.hasPrefix("-") }.count <= 1
        case "awk":
            return autoAllowsAwk(args)
        case "sed":
            return autoAllowsSed(args)
        case "git":
            return autoAllowsGit(args)
        case "gh":
            return autoAllowsGitHub(args)
        default:
            return false
        }
    }

    private static func autoAllowsAwk(_ args: [String]) -> Bool {
        let blockedFlags = ["-f", "--file", "-i", "--include", "-l", "--load", "-E", "--exec"]
        let blockedText = ["system", "|", ">", "getline", "@"]
        return !args.contains { arg in
            blockedFlags.contains { arg.hasPrefix($0) }
                || blockedText.contains { arg.contains($0) }
        }
    }

    private static let sedAddress = #"(?:\d+(?:~\d+)?|\$|/(?:\\.|[^/\\])*/I?)"#
    private static let sedCommand = try! NSRegularExpression(pattern:
        #"^\s*(?:"# + sedAddress + #"(?:\s*,\s*(?:"# + sedAddress + #"|[+~]\d+))?\s*!?\s*)?"#
        + #"(?:[pP=lqQdn]|s/(?:\\.|[^/\\])*/(?:\\.|[^/\\])*/[gpiI0-9]*)?\s*$"#)

    /// `sed -n` whose scripts only print: no `-i`, `-f`, `w`, `e` or `r`.
    private static func autoAllowsSed(_ args: [String]) -> Bool {
        var quiet = false
        var scripts: [String] = []
        var positionals: [String] = []
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "-e" || arg == "--expression" {
                guard let script = iterator.next() else { return false }
                scripts.append(script)
            } else if arg.hasPrefix("--expression=") {
                scripts.append(String(arg.dropFirst("--expression=".count)))
            } else if ["--quiet", "--silent"].contains(arg) {
                quiet = true
            } else if ["--regexp-extended", "--separate", "--unbuffered", "--null-data", "--posix", "--"].contains(arg) {
                continue
            } else if arg.hasPrefix("-"), arg.count > 1, !arg.hasPrefix("--") {
                let flags = arg.dropFirst()
                guard flags.allSatisfy({ "nErsuz".contains($0) }) else { return false }
                if flags.contains("n") { quiet = true }
            } else if arg.hasPrefix("--") {
                return false
            } else {
                positionals.append(arg)
            }
        }
        if scripts.isEmpty {
            guard !positionals.isEmpty else { return false }
            scripts.append(positionals.removeFirst())
        }
        guard quiet else { return false }
        return scripts.allSatisfy { script in
            script.split(whereSeparator: { $0 == ";" || $0 == "\n" }).allSatisfy { part in
                let text = String(part)
                return sedCommand.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
    }

    private static let readOnlyGit: Set<String> = [
        "status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog",
        "merge-base", "show-ref", "branch", "tag", "remote", "worktree", "stash", "config",
    ]

    private static func autoAllowsGit(_ args: [String]) -> Bool {
        var rest = args[...]
        // `git -C <dir>` and `--no-pager` are the only global options allowed;
        // `-c key=value` could set a pager or hook.
        while let first = rest.first, first.hasPrefix("-") {
            if first == "-C", rest.count > 1 {
                rest = rest.dropFirst(2)
            } else if first == "--no-pager" {
                rest = rest.dropFirst()
            } else {
                return false
            }
        }
        guard let sub = rest.first, readOnlyGit.contains(sub) else { return false }
        let subArgs = Array(rest.dropFirst())
        if subArgs.contains(where: { $0.hasPrefix("--output") }) { return false }
        let positionals = subArgs.filter { !$0.hasPrefix("-") }
        switch sub {
        case "branch":
            return autoAllowsGitBranch(subArgs)
        case "tag":
            let creating = ["-d", "--delete", "-a", "--annotate", "-s", "--sign", "-u", "-f", "--force", "-m", "-F", "-e"]
            if subArgs.contains(where: { creating.contains($0) }) { return false }
            return positionals.isEmpty || subArgs.contains { $0 == "-l" || $0 == "--list" }
        case "remote":
            return positionals.isEmpty || ["get-url", "show"].contains(positionals[0])
        case "worktree":
            return positionals.first == "list"
        case "stash":
            return ["list", "show"].contains(positionals.first ?? "")
        case "config":
            let reads = ["--get", "--get-all", "--get-regexp", "--list", "-l"]
            return subArgs.contains { reads.contains($0) }
                && !subArgs.contains { ["--add", "--unset", "--unset-all", "--replace-all", "--edit", "-e",
                                         "--rename-section", "--remove-section"].contains($0) }
        default:
            return true
        }
    }

    /// `git branch` in listing mode only.
    private static func autoAllowsGitBranch(_ args: [String]) -> Bool {
        let listingFlags: Set<String> = [
            "--list", "--all", "--remotes", "--verbose", "--show-current", "--contains", "--no-contains",
            "--merged", "--no-merged", "--points-at", "--column", "--no-column", "--color", "--no-color",
            "--abbrev", "--no-abbrev", "--ignore-case", "--omit-empty",
        ]
        let listingValues = ["--sort=", "--format=", "--color=", "--contains=", "--no-contains=", "--merged=",
                             "--no-merged=", "--points-at=", "--abbrev=", "--column="]
        let listMode: Set<String> = ["--list", "-l", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"]
        var sawListMode = false
        var sawPositional = false
        for arg in args {
            if arg.hasPrefix("--") {
                guard listingFlags.contains(arg) || listingValues.contains(where: { arg.hasPrefix($0) }) else { return false }
            } else if arg.hasPrefix("-"), arg.count > 1 {
                guard arg.dropFirst().allSatisfy({ "avrl".contains($0) }) else { return false }
            } else {
                sawPositional = true
            }
            let shortList = arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.contains("l")
            let valueList = ["--contains=", "--no-contains=", "--merged=", "--no-merged=", "--points-at="]
                .contains { arg.hasPrefix($0) }
            if listMode.contains(arg) || shortList || valueList { sawListMode = true }
        }
        // A bare `git branch <name>` creates a branch.
        return !sawPositional || sawListMode
    }

    private static let readOnlyGitHub: [String: Set<String>] = [
        "issue": ["view", "list", "status"],
        "pr": ["view", "list", "diff", "checks", "status"],
        "run": ["view", "list"],
        "workflow": ["view", "list"],
        "release": ["view", "list"],
        "repo": ["view"],
        "search": ["issues", "prs", "repos", "code", "commits"],
    ]

    private static func autoAllowsGitHub(_ args: [String]) -> Bool {
        guard args.count >= 2, let allowed = readOnlyGitHub[args[0]] else { return false }
        return allowed.contains(args[1])
    }

    /// `argv` as one shell line, quoting each argument that needs it, so a
    /// legacy Codex `["/bin/zsh", "-lc", "a | b"]` unwraps to `a | b`.
    static func shellJoin(_ argv: [String]) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=,@%+")
        return argv.map { arg in
            if !arg.isEmpty, arg.unicodeScalars.allSatisfy({ plain.contains($0) }) { return arg }
            return "'" + arg.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
        }.joined(separator: " ")
    }

    /// The inner command of `bash -lc '…'`, `zsh -c "…"` and the like, or
    /// `command` itself.
    static func unwrapShell(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let shells = ["sh", "bash", "zsh"]
        for shell in shells {
            for prefix in ["/bin/\(shell) ", "/usr/bin/\(shell) ", "\(shell) "] {
                for flag in ["-lc ", "-c "] where trimmed.hasPrefix(prefix + flag) {
                    let rest = String(trimmed.dropFirst(prefix.count + flag.count))
                    // The script must be exactly one shell word; the inner
                    // line is checked again on its own.
                    if let stages = ChiefShellLexer.stages(of: rest), stages.count == 1, stages[0].count == 1 {
                        return stages[0][0].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return trimmed
                }
            }
        }
        return trimmed
    }

    /// A short title for a Claude Code tool call, such as the `description`
    /// of a `Bash` call or `Read Sources/App.swift`.
    ///
    /// - Parameters:
    ///   - tool: The tool name.
    ///   - input: The tool's input.
    static func claudeTitle(_ tool: String, input: ChiefJSON) -> String {
        let text: String
        switch tool {
        case "Bash":
            text = nonEmpty(input["description"]?.string) ?? input["command"]?.string ?? "Run a command"
        case "Read":
            text = "Read " + (input["file_path"]?.string ?? "a file")
        case "Write":
            text = "Write " + (input["file_path"]?.string ?? "a file")
        case "Edit", "MultiEdit":
            text = "Edit " + (input["file_path"]?.string ?? "a file")
        case "Glob", "Grep":
            text = "Search " + (input["pattern"]?.string ?? "files")
        case "WebFetch":
            text = "Fetch " + (input["url"]?.string ?? "a page")
        case "WebSearch":
            text = "Search the web: " + (input["query"]?.string ?? "")
        case "ToolSearch":
            text = "Find tools"
        default:
            // MCP tools are `mcp__server__tool`; the last part reads best.
            let parts = tool.components(separatedBy: "__")
            text = parts.count >= 3 ? parts.dropFirst(2).joined(separator: "__") : tool
        }
        return truncate(text.replacingOccurrences(of: "\n", with: " "), to: 80)
    }

    /// The full input of a tool call for its work card: the command for a
    /// shell call, compact JSON otherwise.
    static func claudeDetail(_ tool: String, input: ChiefJSON) -> String? {
        if tool == "Bash", let command = input["command"]?.string { return command }
        if case .object(let members) = input, members.isEmpty { return nil }
        return truncate(input.compactText, to: 4000)
    }

    /// The approval prompt for a Claude Code permission request.
    static func claudePrompt(_ tool: String, input: ChiefJSON) -> String {
        if tool == "Bash", let command = input["command"]?.string {
            return "Run `\(truncate(command, to: 300))`?"
        }
        return "Allow \(claudeTitle(tool, input: input))?"
    }

    /// The first few lines of a tool result, for a finished work card.
    ///
    /// - Parameter text: The tool's output.
    /// - Returns: Up to 3 lines and 240 characters, nil for empty output.
    static func preview(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(3)
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : truncate(joined, to: 240)
    }

    /// `text` cut to `limit` characters with an ellipsis.
    static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }
}
