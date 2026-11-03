import Foundation

/// The socket-free half of `cmux chief dispatch`: argument parsing, the
/// launcher script that hands the agent its task, the worktree layout, and
/// reading a terminal for proof that the agent is working.
///
/// The task never passes through a shell parser. The CLI writes it to a
/// private file (mode 0600 in a fresh 0700 directory), and the new
/// terminal types one fixed line, `/bin/sh '<dir>/launch.sh'`. The launcher
/// reads the file into a variable, deletes the directory and `exec`s the
/// agent with the task as one argv element (`"$prompt"`), so quotes, `$`,
/// backticks and newlines in the task reach the agent unchanged. Every other
/// word of the script is single-quoted by ``shellWord(_:)``.
///
/// This file is compiled into the `cmux` CLI and into `cmuxCLITests`; it must
/// not use `CMUXCLI` or the socket client.
enum ChiefDispatchAgent: String, CaseIterable, Equatable {
    case codex
    case claude

    /// The command line used when the caller passes no `--agent-arg`.
    /// Both agents keep their normal permission prompts unless the caller
    /// explicitly adds a bypass flag.
    var defaultArguments: [String] {
        switch self {
        case .codex: return ["codex"]
        case .claude: return ["claude"]
        }
    }
}

/// Where the task text comes from.
enum ChiefDispatchPromptSource: Equatable {
    /// Words after `--` (or bare positionals), joined with single spaces.
    case words(String)
    /// `--prompt-file <path>`.
    case file(String)
    /// `--prompt-file -`.
    case standardInput
}

/// Parsed `cmux chief dispatch` arguments.
struct ChiefDispatchOptions: Equatable {
    static let defaultTimeout = 60
    static let maxTimeout = 600
    /// macOS caps argv plus environment near 1 MiB; stay far below it.
    static let maxPromptBytes = 200_000

    var agent: ChiefDispatchAgent = .codex
    var name: String?
    var cwd: String?
    var worktreeRepo: String?
    var branch: String?
    /// Extra agent arguments (`--agent-arg`), appended after the defaults.
    var agentArguments: [String] = []
    /// nil: the caller passed neither `--focus` nor `--no-focus`.
    var focus: Bool?
    var waitWorking = false
    var timeout = ChiefDispatchOptions.defaultTimeout
    var prompt: ChiefDispatchPromptSource = .words("")

    /// Whether the arguments after `cmux chief dispatch` ask for help: `--help`
    /// or `-h` before `--`, so a task that mentions either still dispatches.
    static func isHelpRequest(_ args: [String]) -> Bool {
        let flags = args.firstIndex(of: "--").map { args[..<$0] } ?? args[...]
        return flags.contains("--help") || flags.contains("-h")
    }

    /// Parses the arguments after `cmux chief dispatch`. Value flags take
    /// `--flag value` or `--flag=value`; everything after `--` is the task.
    static func parse(_ args: [String]) throws -> ChiefDispatchOptions {
        var options = ChiefDispatchOptions()
        var words: [String] = []
        var promptFile: String?
        var timeoutGiven = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                words.append(contentsOf: args[(index + 1)...])
                break
            }
            var flag = arg
            var inlineValue: String?
            if arg.hasPrefix("--"), let equals = arg.firstIndex(of: "=") {
                flag = String(arg[..<equals])
                inlineValue = String(arg[arg.index(after: equals)...])
            }
            func value() throws -> String {
                if let inlineValue { return inlineValue }
                guard index + 1 < args.count else {
                    throw CLIError(message: String(
                        format: String(localized: "cli.chief.error.missingValue", defaultValue: "%@ needs a value."),
                        flag
                    ))
                }
                index += 1
                return args[index]
            }
            switch flag {
            case "--agent":
                let raw = try value()
                guard let agent = ChiefDispatchAgent(rawValue: raw.lowercased()) else {
                    throw CLIError(message: String(
                        format: String(
                            localized: "cli.chief.dispatch.error.unknownAgent",
                            defaultValue: "Unknown agent: %@. Use codex or claude."
                        ),
                        raw
                    ))
                }
                options.agent = agent
            case "--name":
                let name = try value().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !name.contains(where: \.isNewline) else {
                    throw CLIError(message: String(
                        localized: "cli.chief.dispatch.error.invalidName",
                        defaultValue: "--name needs a one-line title."
                    ))
                }
                options.name = name
            case "--cwd":
                options.cwd = try value()
            case "--worktree":
                options.worktreeRepo = try value()
            case "--branch":
                options.branch = try value()
            case "--agent-arg":
                try options.agentArguments.append(value())
            case "--prompt-file":
                promptFile = try value()
            case "--timeout":
                let raw = try value()
                guard let seconds = Int(raw), seconds > 0, seconds <= maxTimeout else {
                    throw CLIError(message: String(
                        localized: "cli.chief.dispatch.error.invalidTimeout",
                        defaultValue: "--timeout must be a whole number of seconds from 1 to 600."
                    ))
                }
                options.timeout = seconds
                timeoutGiven = true
            case "--wait-working":
                options.waitWorking = true
            case "--focus":
                options.focus = true
            case "--no-focus":
                options.focus = false
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: String(
                        format: String(localized: "cli.chief.error.unknownFlag", defaultValue: "Unknown flag: %@"),
                        arg
                    ))
                }
                words.append(arg)
            }
            index += 1
        }
        // `--timeout` alone means "wait this long".
        if timeoutGiven { options.waitWorking = true }

        if options.branch != nil, options.worktreeRepo == nil {
            throw CLIError(message: String(
                localized: "cli.chief.dispatch.error.branchNeedsWorktree",
                defaultValue: "--branch only applies with --worktree."
            ))
        }
        if options.cwd != nil, options.worktreeRepo != nil {
            throw CLIError(message: String(
                localized: "cli.chief.dispatch.error.cwdAndWorktree",
                defaultValue: "Use --cwd or --worktree, not both: the new worktree is the agent's directory."
            ))
        }
        let text = words.joined(separator: " ")
        if let promptFile {
            guard words.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.chief.dispatch.error.twoPrompts",
                    defaultValue: "Give the task once: after -- or with --prompt-file, not both."
                ))
            }
            options.prompt = promptFile == "-" ? .standardInput : .file(promptFile)
        } else {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: missingPromptMessage)
            }
            options.prompt = .words(text)
        }
        return options
    }

    static var missingPromptMessage: String {
        String(
            localized: "cli.chief.dispatch.error.noPrompt",
            defaultValue: "No task. Give it after --, or with --prompt-file <path|-> (- reads stdin)."
        )
    }

    /// The task text as the agent receives it, or an error for an empty or oversized one.
    ///
    /// Surrounding whitespace is trimmed. A task that starts with `-` gets one
    /// leading space so the agent's option parser cannot read it as a flag.
    static func normalizedPrompt(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIError(message: missingPromptMessage) }
        guard trimmed.utf8.count <= maxPromptBytes, !trimmed.contains("\0") else {
            throw CLIError(message: String(
                localized: "cli.chief.dispatch.error.promptTooLong",
                defaultValue: "The task is too long (over 200,000 bytes) or contains a NUL byte. Put the details in a file and tell the agent to read it."
            ))
        }
        return trimmed.hasPrefix("-") ? " " + trimmed : trimmed
    }

    /// The agent's full command line.
    var agentCommand: [String] { agent.defaultArguments + agentArguments }

    /// The workspace title: `--name`, else the task's first line, shortened.
    func title(prompt: String) -> String {
        if let name { return name }
        return Self.defaultTitle(for: prompt)
    }

    static func defaultTitle(for prompt: String, limit: Int = 40) -> String {
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed.isEmpty ? "agent" : collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Files and command lines `cmux chief dispatch` builds.
enum ChiefDispatchPlan {
    /// One POSIX shell word: always single-quoted, each `'` spliced as `'"'"'`.
    static func shellWord(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// The launcher `/bin/sh` runs in the new terminal. It reads the task,
    /// removes the private directory (task file and itself) and replaces
    /// itself with the agent, so the agent's argv holds the task as one word.
    static func launcherScript(agentCommand: [String], promptPath: String, directory: String) -> String {
        let command = agentCommand.map(shellWord).joined(separator: " ")
        return """
        #!/bin/sh
        # Written by cmux chief dispatch. Hands the agent its task, then removes itself.
        prompt=$(cat -- \(shellWord(promptPath))) || exit 1
        rm -rf -- \(shellWord(directory))
        exec \(command) "$prompt"

        """
    }

    /// The line typed into the new terminal's shell. It parses the same in
    /// zsh, bash and fish; the leading space keeps it out of shell history
    /// where `HIST_IGNORE_SPACE`-style settings are on.
    static func typedCommand(launcherPath: String) -> String {
        " /bin/sh " + shellWord(launcherPath)
    }

    /// A branch and directory name from a title: lowercase ASCII letters,
    /// digits and single dashes, at most 48 characters
    /// (`#123: Fix login` -> `123-fix-login`); `agent` when nothing is left.
    static func slug(_ text: String, limit: Int = 48) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out.append("-")
            }
        }
        var trimmed = String(out.prefix(limit))
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        return trimmed.isEmpty ? "agent" : trimmed
    }

    /// Where `--worktree <repo>` puts the new checkout: next to the repository,
    /// as `<repo-name>-<slug>` (`~/src/app` + `fix-login` -> `~/src/app-fix-login`).
    static func worktreePath(repo: String, slug: String) -> String {
        let url = URL(fileURLWithPath: repo, isDirectory: true).standardizedFileURL
        let parent = url.deletingLastPathComponent()
        return parent.appendingPathComponent("\(url.lastPathComponent)-\(slug)", isDirectory: true).path
    }

    /// `git` arguments that create the worktree on a new branch from the repository's HEAD.
    static func worktreeAddArguments(repo: String, path: String, branch: String) -> [String] {
        ["-C", repo, "worktree", "add", "-b", branch, "--", path]
    }
}

/// What a terminal shows about a just-launched agent.
enum ChiefDispatchScreenReading: Equatable {
    /// The agent's activity line (`• Working (3s • esc to interrupt)`).
    case working(String)
    /// The agent stopped at a screen only a person should answer, or never started.
    case blocked(reason: String)
    /// Nothing conclusive yet.
    case pending

    /// Reads a terminal screen for `agent`.
    ///
    /// Working needs the agent's own activity line: Codex's `Working (…)`
    /// row, or a Claude Code spinner row, each with an elapsed timer or
    /// "esc to interrupt". Claude's status bar (which always says "esc to
    /// interrupt") is not proof. Trust, bypass-mode and sign-in screens are
    /// reported, never answered. Matches HQ's `dispatch-agent.py`.
    static func read(_ screen: String, agent: ChiefDispatchAgent) -> ChiefDispatchScreenReading {
        let lines = screen.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines {
            let lower = line.lowercased()
            if agent == .claude, isClaudeStatusBar(line) { continue }
            let hasTimer = lower.range(of: #"\(\s*(?:\d+(?:\.\d+)?\s*[hms]\s*)+"#, options: .regularExpression) != nil
            let hasInterrupt = lower.range(of: #"\besc to (?:interrupt|cancel)\b"#, options: .regularExpression) != nil
            guard hasTimer || hasInterrupt else { continue }
            switch agent {
            case .codex:
                if line.range(of: #"^(?:[•●·]\s*)?Working\s*\("#, options: .regularExpression) != nil {
                    return .working(line)
                }
            case .claude:
                if line.range(of: #"^[✢✳✶✻✽·*⏸⏵]"#, options: .regularExpression) != nil {
                    return .working(line)
                }
            }
        }
        let joined = lines.joined(separator: " ")
        if agent == .claude,
           joined.contains("No, exit"),
           joined.contains("Yes, I trust this folder") || joined.contains("Do you trust the files in this folder")
            || joined.contains("Bypass Permissions mode") {
            return .blocked(reason: "trust_prompt")
        }
        if agent == .claude, lines.contains(where: { line in
            let lower = line.lowercased()
            return line.hasPrefix("⎿") && lower.contains("not logged in") && lower.contains("/login")
        }) {
            return .blocked(reason: "sign_in")
        }
        if agent == .codex, joined.contains("Sign in with ChatGPT") {
            return .blocked(reason: "sign_in")
        }
        let program = agent.rawValue
        if lines.contains(where: { line in
            (line.range(of: #"^(?:zsh|bash|sh|fish): (?:command not found|Unknown command)"#, options: .regularExpression) != nil
                && line.contains(program))
                || line.contains("exec: \(program): not found")
                || line.hasSuffix("\(program): command not found")
        }) {
            return .blocked(reason: "agent_not_found")
        }
        return .pending
    }

    private static func isClaudeStatusBar(_ line: String) -> Bool {
        line.lowercased().contains("shift+tab to cycle") || line.hasPrefix("⏵⏵")
    }
}

/// One `surface.wait_text_change` reply, read for `--wait-working`.
struct ChiefDispatchWaitStep: Equatable {
    /// What the terminal showed in this reply.
    let reading: ChiefDispatchScreenReading
    /// The revision to wait after next, from the reply.
    let revision: String?
    /// The wait is over: the agent is working, the app answered without a
    /// change (its deadline passed), or the reply has no revision to wait on.
    let isFinal: Bool

    static func read(_ payload: [String: Any], agent: ChiefDispatchAgent) -> ChiefDispatchWaitStep {
        let reading = ChiefDispatchScreenReading.read(payload["text"] as? String ?? "", agent: agent)
        let revision = (payload["revision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let working = if case .working = reading { true } else { false }
        let unchanged = payload["changed"] as? Bool == false
        return ChiefDispatchWaitStep(
            reading: reading,
            revision: revision,
            isFinal: working || unchanged || revision == nil
        )
    }
}
