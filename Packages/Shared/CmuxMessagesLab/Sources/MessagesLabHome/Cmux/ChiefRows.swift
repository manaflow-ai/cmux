import CmuxAgentQuestion
import CmuxHomeCore
import Foundation

/// The Chief's tool calls and approval requests as MessagesLab hosted rows
/// (`Part.custom`, Vendor/catalyst/CustomRows.swift, live views in the vendored
/// CustomRowsHost). Pure values and the mapping rules; the views are
/// `ChiefToolRowProvider` and `ChiefApprovalRowProvider`.
///
/// Tool calls (`MessagePart.work`, one Chief message per call) show as a compact
/// row on the Chief's side, not a bubble: glyph, "Ran `cmux tree --all`", state.
/// Consecutive tool-only messages of one author in one thread are one run; the
/// run's first message carries the row for the whole run ("Ran 3 commands",
/// expandable) and the later ones show nothing (`ToolRole.folded`: a message
/// with no parts, so the transcript's window count stays the HomeStore count).
/// A tool row's message is drawn as another sender (`toolSender`), so it ends
/// the bubble group above it like a sender change: the bubble above keeps its
/// tail and the bubble below starts a new group.
///
/// Approvals (`MessagePart.approval`) are an incoming bubble card with the
/// prompt and one button per option; the answer goes to the owner as
/// `HomeOp.answerQuestion` addressing the approval part (`ChiefApprovalAnswer`).
enum ChiefRows {
    static let toolKind = "cmux.chief.tools"
    static let approvalKind = "cmux.chief.approval"
    /// The suffix of a tool row's sender id (`toolSender`).
    static let toolSenderSuffix = "#tools"

    /// The id a tool row's message is drawn as sent by.
    static func toolSender(_ author: ParticipantID) -> String { author.rawValue + toolSenderSuffix }

    // MARK: Payloads

    /// One tool call in a row.
    struct ToolCall: Codable, Hashable {
        enum State: String, Codable, Hashable { case running, done, failed }
        var id: String
        var title: String
        var state: State
        /// The command or the result's first lines (tooltip, Copy).
        var detail: String?

        init(id: String, title: String, state: State, detail: String? = nil) {
            self.id = id
            self.title = title
            self.state = state
            self.detail = detail
        }

        init(_ work: WorkRef) {
            let state: State
            switch work.status {
            case .running, .waiting: state = .running
            case .done: state = .done
            case .failed: state = .failed
            }
            self.init(id: work.session, title: work.title, state: state, detail: work.preview)
        }

        var kind: ToolKind { ToolKind(title: title) }
    }

    /// A tool row: one call, or a run of calls (`group` is the run's first message id).
    struct Tools: Codable, Hashable {
        var group: String
        var calls: [ToolCall]

        /// Running while any call runs; failed when any failed; else done.
        var state: ToolCall.State {
            if calls.contains(where: { $0.state == .running }) { return .running }
            if calls.contains(where: { $0.state == .failed }) { return .failed }
            return .done
        }
    }

    /// An approval card: pending, a bubble with the prompt and the options; decided, a one-line receipt.
    struct Approval: Codable, Hashable {
        var request: String
        var prompt: String
        var options: [String]
        var decided: String?
        /// The asking agent's name ("Chief"), for the caption.
        var agent: String?

        init(request: String, prompt: String, options: [String], decided: String? = nil, agent: String? = nil) {
            self.request = request
            self.prompt = prompt
            self.options = options
            self.decided = decided
            self.agent = agent
        }

        init(_ ref: ApprovalRef, agent: String? = nil) {
            self.init(request: ref.request, prompt: ref.prompt, options: ref.options, decided: ref.decided, agent: agent)
        }

        var isPending: Bool { decided == nil }

        /// The tinted option: the first that grants ("Allow", "Approve", "Yes"), else the last.
        var prominent: String? { options.first(where: ChiefRows.grants) ?? options.last }
        /// The option Esc picks: the first that refuses ("Deny", "Decline", "No", "Reject"), else nil.
        var refusal: String? { options.first(where: ChiefRows.refuses) }
        /// The buttons left to right: the prominent option last (the default button's place on the Mac).
        var buttonOrder: [String] {
            guard let p = prominent else { return options }
            return options.filter { $0 != p } + [p]
        }
        /// The shell command a "Run `…`?" prompt asks for (ChiefToolPolicy.claudePrompt), nil for other prompts.
        var command: String? { ChiefRows.command(inPrompt: prompt) }
        /// The "Always Allow" prefix for the command ("cmux tree"), nil when none is offered.
        var alwaysAllowPrefix: String? {
            guard prominent.map(ChiefRows.grants) == true, let command else { return nil }
            return ChiefRows.alwaysAllowWords(command).map { $0.joined(separator: " ") }
        }
    }

    /// The command of a "Run `<command>`?" prompt.
    static func command(inPrompt prompt: String) -> String? {
        guard prompt.hasPrefix("Run `") else { return nil }
        let rest = prompt.dropFirst("Run `".count)
        guard let end = rest.lastIndex(of: "`") else { return nil }
        let command = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// The words an "Always Allow" rule for `command` names: the program and its subcommand
    /// ("cmux tree", "git push"), only for one plain simple command (no pipes, lists, redirects,
    /// quotes, globs or expansion), never for a shell, an interpreter, a deleting program, `git
    /// config`, `npx`, `npm exec|run`, `make`, a `cmux` group that runs commands or answers for
    /// the user (`vm`, `chief`, `browser`, `send*`), or a `cmux` call with a word that asks.
    /// The owner derives and honors the same rule (ChiefAllowRules.prefix and
    /// ChiefToolPolicy.cmuxWordAsks in CmuxChief, the same lists; change both).
    static func alwaysAllowWords(_ command: String) -> [String]? {
        let banned = CharacterSet(charactersIn: "|&;<>`$(){}[]\\\"'*?~=#^\n\t")
        guard command.rangeOfCharacter(from: banned) == nil else { return nil }
        let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2 else { return nil }
        let program = words[0], sub = words[1]
        guard program.range(of: #"^[a-z][a-z0-9._-]*$"#, options: .regularExpression) != nil,
              sub.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil,
              !alwaysAllowRefusedPrograms.contains(program) else { return nil }
        if program == "cmux" {
            if words.dropFirst().contains(where: cmuxWordAsks) { return nil }
            // A group's rule names its verb too ("cmux chief dispatch", never all of "cmux chief").
            if let verbs = alwaysAllowCmuxGroupVerbs[sub] {
                return words.count >= 3 && verbs.contains(words[2]) ? Array(words.prefix(3)) : nil
            }
        }
        if alwaysAllowRefusedSubcommands[program]?.contains(sub) ?? false { return nil }
        return [program, sub]
    }

    /// ChiefAllowRules.cmuxGroupVerbs in CmuxChief (the same table; change both).
    static let alwaysAllowCmuxGroupVerbs: [String: Set<String>] = ["chief": ["dispatch"]]

    /// ChiefAllowRules.refusedPrograms in CmuxChief (the same list; change both).
    static let alwaysAllowRefusedPrograms: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "nu", "pwsh",
        "sudo", "su", "doas", "env", "xargs", "eval", "exec", "command", "builtin", "nohup", "time", "timeout",
        "nice", "watch", "python", "python2", "python3", "node", "deno", "bun", "ruby", "perl", "php", "lua",
        "osascript", "swift", "awk", "gawk", "sed", "find", "rm", "rmdir", "dd", "mv", "chmod", "chown", "chgrp",
        "kill", "killall", "pkill", "npx", "bunx", "pnpx", "uvx", "make", "gmake", "cmake", "ninja", "just",
    ]

    /// ChiefAllowRules.refusedSubcommands in CmuxChief (the same table; change both).
    static let alwaysAllowRefusedSubcommands: [String: Set<String>] = [
        "git": ["config", "submodule", "filter-branch"],
        "npm": ["exec", "run", "run-script", "x", "start", "test"],
        "pnpm": ["exec", "run", "dlx", "x", "start", "test"],
        "yarn": ["exec", "run", "dlx", "start", "test"],
        "uv": ["run", "tool"],
        "pipx": ["run"],
        "cargo": ["run"],
        "go": ["run", "generate"],
        "docker": ["run", "exec"],
        "kubectl": ["exec", "run"],
        "cmux": [
            "vm", "cloud", "chief", "browser", "sudo", "rpc", "ssh", "mosh", "mosh-tmux", "ssh-tmux", "hooks",
            "set-hook", "pipe-pane", "respawn-pane", "automation", "auth", "login", "logout", "ai-accounts",
            "paste", "paste-buffer", "new-workspace", "new-split", "new-pane", "new-surface", "restore-session",
            "import", "feedback", "sessions", "session", "remotes", "remote", "glaeda", "coderouter", "cr",
        ],
    ]

    /// Whether a word of a cmux call asks (ChiefToolPolicy.cmuxWordAsks in CmuxChief, the same
    /// lists; change both): the part before any `=`, lowercased, is a listed word or starts with a
    /// listed prefix.
    static func cmuxWordAsks(_ word: String) -> Bool {
        let lower = word.lowercased()
        let key = lower.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? lower
        return cmuxApprovalWords.contains(key) || cmuxApprovalPrefixes.contains { key.hasPrefix($0) }
    }

    /// ChiefToolPolicy.cmuxApprovalWords in CmuxChief (the same list; change both).
    static let cmuxApprovalWords: Set<String> = [
        "close", "rm", "remove", "delete", "destroy", "kill", "quit", "restart", "relaunch", "reset",
        "clear", "clear-history", "cleanup", "ssh-session-cleanup", "uninstall", "logout",
        "sudo", "rpc", "pipe-pane", "respawn-pane", "set-hook",
        "publish", "access", "grant", "ungrant", "upload", "feedback", "promote-template",
        "send", "paste", "paste-buffer", "exec", "run", "eval", "repl", "shell", "ssh", "mosh",
        "approve", "addscript", "addinitscript",
        "--force", "--yes", "--command", "--eval", "--layout",
    ]

    /// ChiefToolPolicy.cmuxApprovalPrefixes in CmuxChief (the same list; change both).
    static let cmuxApprovalPrefixes = [
        "close-", "kill-", "clear-", "send-", "delete-", "remove-", "--force", "--yes", "--command", "--eval",
    ]

    /// The decided value of an expired card (ChiefConversationOwner.approvalExpired in CmuxChief, the same id).
    static let expiredDecision = "expired"

    static func grants(_ option: String) -> Bool {
        ["allow", "approve", "yes", "run", "allow once"].contains(option.lowercased())
    }

    static func refuses(_ option: String) -> Bool {
        ["deny", "decline", "no", "reject", "cancel", "skip"].contains(option.lowercased())
    }

    // MARK: Tool kinds

    /// What a tool call did, from its title (ChiefToolPolicy.claudeTitle, the Codex parser's titles):
    /// its glyph, and which part of the title is code (monospaced).
    enum ToolKind: Hashable {
        /// A shell command: the whole title is the command.
        case command
        /// A description of a shell command ("List workspaces"): plain text.
        case described
        /// "Read <path>", "Write <path>", "Edit <path>": `verb` and the path.
        case file(verb: String)
        /// "Search <pattern>", "Search the web: <query>", "Find tools".
        case search(verb: String)
        /// "Fetch <url>".
        case fetch(verb: String)

        init(title: String) {
            let t = title.trimmingCharacters(in: .whitespaces)
            for verb in ["Read ", "Write ", "Edit "] where t.hasPrefix(verb) { self = .file(verb: verb); return }
            for verb in ["Search the web: ", "Search "] where t.hasPrefix(verb) { self = .search(verb: verb); return }
            if t == "Find tools" { self = .search(verb: ""); return }
            if t.hasPrefix("Fetch ") { self = .fetch(verb: "Fetch "); return }
            self = ToolKind.looksLikeCommand(t) ? .command : .described
        }

        /// A title that is a shell command, not a sentence: shell punctuation or flags,
        /// a path, or a first word that is a known program.
        static func looksLikeCommand(_ t: String) -> Bool {
            guard !t.isEmpty else { return false }
            if t.contains(" --") || t.range(of: #" -[A-Za-z]"#, options: .regularExpression) != nil { return true }
            if t.rangeOfCharacter(from: CharacterSet(charactersIn: "|&;<>$`=/~")) != nil { return true }
            let first = t.split(separator: " ").first.map(String.init) ?? t
            let programs: Set<String> = ["cmux", "git", "gh", "ls", "cat", "cd", "rg", "grep", "find", "npm", "npx", "bun", "pnpm",
                                         "yarn", "swift", "xcodebuild", "make", "python", "python3", "node", "curl", "open", "echo",
                                         "sed", "awk", "head", "tail", "mkdir", "rm", "cp", "mv", "touch", "brew", "cargo", "go",
                                         "docker", "kubectl", "ssh", "tmux", "jq", "pwd", "which", "env", "sh", "bash", "zsh"]
            return programs.contains(first)
        }

        /// The SF Symbol for the row.
        var symbol: String {
            switch self {
            case .command, .described: return "terminal"
            case .file(let verb): return verb == "Read " ? "doc.text" : "pencil"
            case .search: return "magnifyingglass"
            case .fetch: return "globe"
            }
        }

        /// The title in the user's language around `code` ("Read %@"), nil for a
        /// command or a description (shown as the owner wrote it).
        func localizedFrame(_ code: String) -> String? {
            switch self {
            case .command, .described: return nil
            case .file(let verb):
                return verb == "Read " ? CmuxStrings.toolRead(code) : verb == "Write " ? CmuxStrings.toolWrite(code)
                    : CmuxStrings.toolEdit(code)
            case .search(let verb):
                if verb.isEmpty { return CmuxStrings.toolFindTools }
                return verb == "Search the web: " ? CmuxStrings.toolSearchWeb(code) : CmuxStrings.toolSearch(code)
            case .fetch:
                return CmuxStrings.toolFetch(code)
            }
        }

        /// (plain prefix, code) of a title: the code part is drawn monospaced.
        func split(_ title: String) -> (plain: String, code: String) {
            switch self {
            case .command: return ("", title)
            case .described: return (title, "")
            case .file(let verb), .search(let verb), .fetch(let verb):
                guard !verb.isEmpty, title.hasPrefix(verb) else { return (title, "") }
                return (verb, String(title.dropFirst(verb.count)))
            }
        }
    }

    // MARK: Runs

    /// How one transcript item shows.
    enum ToolRole: Hashable {
        /// Not a tool message.
        case other
        /// The first message of a run: the row for every call in it.
        case head([ToolCall])
        /// A later message of a run: no row (its call is in the head's).
        case folded
    }

    /// Tool-only messages: every part is a tool call (`.work` without a `host`), not retracted. A work part
    /// with a host is a flow's own row (a Cloud machine's provisioning or result card): it stays a row of
    /// its own, never folded into a run.
    static func isToolOnly(_ item: TranscriptItem) -> Bool {
        !item.isRetracted && !item.parts.isEmpty && item.parts.allSatisfy {
            if case .work(let w) = $0 { w.host == nil && !ChiefCloudRows.isProvisioning(w) } else { false }
        }
    }

    /// Messages drawn as the tool sender (`toolSender`): tool rows and approval cards, which are not the
    /// agent's words (they end its bubble group, and its next words start a new one).
    static func drawsAsToolSender(_ item: TranscriptItem) -> Bool {
        !item.isRetracted && !item.parts.isEmpty && item.parts.allSatisfy {
            switch $0 {
            case .work, .approval: return true
            default: return false
            }
        }
    }

    /// The tool role of each item, by key. A run is consecutive tool-only items of one author
    /// in one thread (another message between, even a folded draft, ends it).
    static func roles(_ items: [TranscriptItem]) -> [IdempotencyKey: ToolRole] {
        var out: [IdempotencyKey: ToolRole] = [:]
        var head: TranscriptItem?
        var calls: [ToolCall] = []
        func close() {
            if let head { out[head.key] = .head(calls) }
            head = nil
            calls = []
        }
        for item in items {
            guard isToolOnly(item) else { close(); continue }
            if let h = head, h.author == item.author, h.threadRoot == item.threadRoot {
                out[item.key] = .folded
            } else {
                close()
                head = item
            }
            for case .work(let w) in item.parts { calls.append(ToolCall(w)) }
        }
        close()
        return out
    }

    /// The custom part of a tool row.
    static func toolPart(_ calls: [ToolCall], group: String) -> CustomPart {
        part(kind: toolKind, Tools(group: group, calls: calls))
    }

    static func approvalPart(_ ref: ApprovalRef, agent: String? = nil) -> CustomPart {
        part(kind: approvalKind, Approval(ref, agent: agent))
    }

    /// The payload as sorted-key JSON, its version a hash of the bytes: the measure cache and the
    /// row bitmaps key on the version, so it changes exactly when the payload does.
    static func part<T: Encodable>(kind: String, _ value: T) -> CustomPart {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return CustomPart(kind: kind, version: version(of: data), payload: data)
    }

    /// FNV-1a of the bytes, positive (deterministic across launches, unlike `Hasher`).
    static func version(of data: Data) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in data { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return Int(truncatingIfNeeded: h >> 1)
    }

    // MARK: Text

    /// Copy, VoiceOver and the preview: one line per call.
    static func plainText(_ tools: Tools) -> String {
        tools.calls.map { displayTitle($0.title) }.joined(separator: "\n")
    }

    /// A tool title as the user reads it: the owner's English verbs ("Read <path>") in the user's language.
    static func displayTitle(_ title: String) -> String {
        let kind = ToolKind(title: title)
        return kind.localizedFrame(kind.split(title).code) ?? title
    }

    /// An approval prompt as the user reads it: the owner stores "Run `<command>`?" and
    /// "Allow <tool title>?" in English (it parses them); other prompts show as written.
    static func displayPrompt(_ prompt: String) -> String {
        if let command = command(inPrompt: prompt) { return CmuxStrings.approvalRunPrompt(command) }
        if prompt.hasPrefix("Allow "), prompt.hasSuffix("?"), prompt.count > "Allow ?".count {
            return CmuxStrings.approvalAllowPrompt(displayTitle(String(prompt.dropFirst("Allow ".count).dropLast())))
        }
        return prompt
    }

    /// The row's one line: a run's count, or the call itself.
    static func summary(_ tools: Tools) -> String {
        guard tools.calls.count > 1 else { return tools.calls.first.map(lineText) ?? "" }
        let n = tools.calls.count
        return tools.calls.allSatisfy({ $0.kind == .command }) ? CmuxStrings.ranCommands(n) : CmuxStrings.usedTools(n)
    }

    /// A call's line as text ("Ran cmux tree --all", "Read Sources/App.swift").
    static func lineText(_ call: ToolCall) -> String {
        guard call.kind == .command else { return displayTitle(call.title) }
        return call.state == .running ? CmuxStrings.toolRunning(call.title) : CmuxStrings.toolRan(call.title)
    }

    /// Approval prompt runs: (text, isCode) from the prompt's backtick spans ("Run `ls -la`?").
    static func promptRuns(_ prompt: String) -> [(String, Bool)] {
        let pieces = prompt.components(separatedBy: "`")
        // An unmatched backtick (an even piece count): the last piece is not code.
        let unmatched = pieces.count % 2 == 0
        var out: [(String, Bool)] = []
        for (i, piece) in pieces.enumerated() where !piece.isEmpty {
            let last = i == pieces.count - 1
            if unmatched && last { out.append(("`" + piece, false)) } else { out.append((piece, i % 2 == 1)) }
        }
        return out
    }

    /// The decided receipt's text: "Allowed: <command>", "Denied", or the chosen option.
    static func decidedLabel(_ choice: String, command: String? = nil) -> String {
        // The owner's id for a card nobody can answer any more (ChiefConversationOwner.approvalExpired).
        if choice == expiredDecision { return CmuxStrings.approvalExpired }
        if grants(choice) { return command.map(CmuxStrings.approvalAllowedCommand) ?? CmuxStrings.approvalAllowed }
        if refuses(choice) { return CmuxStrings.approvalDenied }
        return CmuxStrings.approvalChose(choice)
    }

    /// The pending card's caption: "Chief wants to run" over a command, else "Chief is asking".
    static func caption(_ approval: Approval) -> String {
        let name = approval.agent.flatMap { $0.isEmpty ? nil : $0 } ?? "Chief"
        return approval.command == nil ? CmuxStrings.approvalAsks(name) : CmuxStrings.approvalWantsToRun(name)
    }

    /// A button's title: Allow and Deny in the user's language, other options as the owner named them.
    static func buttonTitle(_ option: String) -> String {
        switch option.lowercased() {
        case "allow": return CmuxStrings.approvalAllow
        case "deny": return CmuxStrings.approvalDeny
        default: return option
        }
    }
}

/// An approval's answer through `HomeOp.answerQuestion` (CmuxHomeCore has no
/// approval op): the selection of item `item` is the chosen option. The Chief
/// owner reads it when the addressed part is an approval
/// (`ChiefConversationOwner.answerQuestion`).
enum ChiefApprovalAnswer {
    static let item = "approval"

    /// Set on "Always Allow": the owner saves the command's allow rule before it answers.
    static let always = "always"

    static func answer(choice: String, always: Bool = false) -> AgentQuestionAnswer {
        var selections = [item: AgentQuestionAnswer.Selection(optionIDs: [choice])]
        if always { selections[self.always] = AgentQuestionAnswer.Selection(optionIDs: ["1"]) }
        return AgentQuestionAnswer(selections: selections)
    }
}

extension ChiefRows {
    /// The hosted-row providers, registered once before the first rows are derived (HostView.install).
    static func registerProviders() {
        guard !registered else { return }
        registered = true
        CustomRows.register(ChiefToolRowProvider.shared)
        CustomRows.register(ChiefApprovalRowProvider.shared)
        CustomRows.register(QuestionCardRowProvider.shared)
        CustomRows.register(ChiefProvisionRowProvider.shared)
        CustomRows.register(ChiefResultCardProvider.shared)
    }
    private static var registered = false
}
