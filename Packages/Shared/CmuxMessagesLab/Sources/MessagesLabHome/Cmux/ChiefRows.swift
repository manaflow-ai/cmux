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
    /// A failed turn's system row (ChiefNoticeRows.swift).
    static let failureKind = "cmux.chief.failure"
    /// A saved memory note's system row (ChiefNoticeRows.swift).
    static let memoryKind = "cmux.chief.memory"
    /// CmuxChief's `ChiefConversationOwner.failureSessionPrefix` and `memorySessionPrefix`: the work
    /// parts the owner posts for a failed turn and for a saved note (the same ids; change both).
    static let failurePrefix = "chief.failure:"
    static let memoryPrefix = "chief.memory:"

    /// A failed turn's work part (its title is the first-person error).
    static func isFailure(_ work: WorkRef) -> Bool { work.host == nil && work.session.hasPrefix(failurePrefix) }
    /// A saved note's work part (its title is the note; `.failed` once Undo forgot it).
    static func isMemory(_ work: WorkRef) -> Bool { work.host == nil && work.session.hasPrefix(memoryPrefix) }
    /// A system row's work part, not a tool call.
    static func isNotice(_ work: WorkRef) -> Bool { isFailure(work) || isMemory(work) || isStopped(work) }
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

        /// A plain title for a call whose command says less than its effect ("Started Codex in “#12: fix”"
        /// for `cmux chief dispatch`), nil to show the command.
        var humanTitle: String? { ChiefRows.dispatchTitle(title, state: state) }
    }

    /// A tool row: one call, or a run of calls (`group` is the run's first message id).
    struct Tools: Codable, Hashable {
        var group: String
        var calls: [ToolCall]
        /// The run followed an approval the user allowed: one row says both ("Ran … · Allowed").
        /// Nil (not false) otherwise, so older payloads keep their bytes and versions.
        var allowed: Bool?

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
        /// The rule the owner offers under the chevron ("cmux chief dispatch"), nil when none.
        var alwaysAllowRule: String?

        init(request: String, prompt: String, options: [String], decided: String? = nil, agent: String? = nil,
             alwaysAllowRule: String? = nil) {
            self.request = request
            self.prompt = prompt
            self.options = options
            self.decided = decided
            self.agent = agent
            self.alwaysAllowRule = alwaysAllowRule
        }

        /// The owner's rule rides in the options as `always:<words>` (ChiefAllowRules.cardOptions in
        /// CmuxChief derives it once, from lexed words); it becomes ``alwaysAllowRule``, never a button.
        init(_ ref: ApprovalRef, agent: String? = nil) {
            let marker = ChiefRows.alwaysOptionPrefix
            let rule = ref.options.first { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
            self.init(request: ref.request, prompt: ref.prompt, options: ref.options.filter { !$0.hasPrefix(marker) },
                      decided: ref.decided, agent: agent, alwaysAllowRule: rule.flatMap { $0.isEmpty ? nil : $0 })
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
            guard prominent.map(ChiefRows.grants) == true else { return nil }
            return alwaysAllowRule
        }
    }

    /// Marks the option that carries the owner's Always Allow rule (ChiefAllowRules.alwaysOptionPrefix
    /// in CmuxChief, the same id).
    static let alwaysOptionPrefix = "always:"

    /// The command of a "Run `<command>`?" prompt.
    static func command(inPrompt prompt: String) -> String? {
        guard prompt.hasPrefix("Run `") else { return nil }
        let rest = prompt.dropFirst("Run `".count)
        guard let end = rest.lastIndex(of: "`") else { return nil }
        let command = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

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
        /// The first message of a run: the row for every call in it. `allowed`: the head is the
        /// allowed approval the run's first call asked for (its receipt is this row).
        case head([ToolCall], allowed: Bool)
        /// A later message of a run: no row (its call is in the head's).
        case folded
        /// A failed turn's row; `retry`: it is the newest message (Try Again resends the last message).
        case failure(retry: Bool)
        /// A Cloud result card whose machine an earlier provisioning row named ("chief-dogfood-1"):
        /// the card shows the name, the raw machine id stays in its tooltip.
        case cloudResult(name: String)
    }

    /// Tool-only messages: every part is a tool call (`.work` without a `host`), not retracted. A work part
    /// with a host is a flow's own row (a Cloud machine's provisioning or result card): it stays a row of
    /// its own, never folded into a run. So are the owner's system rows (a failure, a saved note).
    static func isToolOnly(_ item: TranscriptItem) -> Bool {
        !item.isRetracted && !item.parts.isEmpty && item.parts.allSatisfy {
            if case .work(let w) = $0 { w.host == nil && !ChiefCloudRows.isProvisioning(w) && !isNotice(w) } else { false }
        }
    }

    /// A failed turn's message: one failure work part.
    static func isFailureOnly(_ item: TranscriptItem) -> Bool {
        guard !item.isRetracted, item.parts.count == 1, case .work(let w)? = item.parts.first else { return false }
        return isFailure(w)
    }

    /// The prompt of an approval-only message the user allowed (its receipt can fold into the run it started).
    static func allowedPrompt(_ item: TranscriptItem) -> String? {
        guard !item.isRetracted, item.parts.count == 1, case .approval(let ref)? = item.parts.first,
              let decided = ref.decided, grants(decided), command(inPrompt: ref.prompt) != nil else { return nil }
        return ref.prompt
    }

    /// The work part of a Cloud provisioning row (one part), nil for any other message.
    static func provisioningWork(_ item: TranscriptItem) -> WorkRef? {
        guard !item.isRetracted, item.parts.count == 1, case .work(let w)? = item.parts.first, ChiefCloudRows.isProvisioning(w) else { return nil }
        return w
    }

    /// Whether `prompt` asks to run a Cloud provisioning command (`cmux vm new`, `cmux cloud new`,
    /// `vm wait`): its provisioning row already says what it does, so the allowed receipt folds into it.
    static func asksToProvision(_ prompt: String) -> Bool {
        guard let command = command(inPrompt: prompt), let all = words(command) else { return false }
        let head = Array(all.prefix(3))
        return ["vm", "cloud"].contains { group in ["new", "wait"].contains { head == ["cmux", group, $0] } }
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
    /// in one thread (another message between, even a folded draft, ends it). An allowed approval
    /// right before a run whose first call it asked for (the call's title is in its prompt) heads
    /// that run: its receipt and the "Ran" row are one row ("Ran … · Allowed"). An allowed Cloud
    /// provisioning command next to its provisioning row (after it, or right before the row posted
    /// again on Allow) folds into that row (it already says what happened). A Cloud result card names the machine an earlier provisioning row named. A failure
    /// row offers Try Again only while it is the newest message. A finished memory save
    /// (`isFinishedMemorySave`) shows nothing: the note's row says it.
    static func roles(_ items: [TranscriptItem]) -> [IdempotencyKey: ToolRole] {
        var out: [IdempotencyKey: ToolRole] = [:]
        var head: TranscriptItem?
        var calls: [ToolCall] = []
        var allowed = false
        var granted: (item: TranscriptItem, prompt: String)?
        // The newest provisioning row of the author's current stretch of messages (another author's
        // message ends it), and the machine names provisioning rows learned (machine id: name).
        var provisioning: TranscriptItem?
        var machineNames: [String: String] = [:]
        func close() {
            // A failed call's result wins over its approval: "Failed <cmd> ✗", never a green "Allowed".
            if let head { out[head.key] = .head(calls, allowed: allowed && !calls.contains { $0.state == .failed }) }
            head = nil
            calls = []
            allowed = false
        }
        let newest = items.last?.key
        for (index, item) in items.enumerated() {
            if let p = provisioning, p.author != item.author || p.threadRoot != item.threadRoot { provisioning = nil }
            if let w = provisioningWork(item) {
                if w.status != .failed, let machine = w.host, let name = w.preview, !name.isEmpty, name != machine {
                    machineNames[machine] = name
                }
                provisioning = item
            } else if !item.isRetracted, item.parts.count == 1, case .work(let w)? = item.parts.first,
                      ChiefCloudRows.isResult(w), let machine = w.host, let name = machineNames.value(for: machine) {
                out[item.key] = .cloudResult(name: name)
            }
            if isFailureOnly(item) {
                close()
                granted = nil
                out[item.key] = .failure(retry: item.key == newest)
                continue
            }
            if let prompt = allowedPrompt(item) {
                close()
                // Its provisioning row is just before it, or (the card took the row's place until the
                // Allow) posted again right after it.
                let next = items.dropFirst(index + 1).first
                let rowAfter = next.map { provisioningWork($0) != nil && $0.author == item.author && $0.threadRoot == item.threadRoot } ?? false
                if provisioning != nil || rowAfter, asksToProvision(prompt) {
                    out[item.key] = .folded
                    granted = nil
                } else {
                    granted = (item, prompt)
                }
                continue
            }
            guard isToolOnly(item) else { close(); granted = nil; continue }
            // A finished memory save shows nothing: the note's row is its receipt.
            if isFinishedMemorySave(item) { close(); granted = nil; out[item.key] = .folded; continue }
            let first = item.parts.lazy.compactMap { p -> WorkRef? in if case .work(let w) = p { w } else { nil } }.first
            if let h = head, h.author == item.author, h.threadRoot == item.threadRoot {
                out[item.key] = .folded
            } else if let g = granted, g.item.author == item.author, g.item.threadRoot == item.threadRoot,
                      let first, ChiefRows.asksFor(first, prompt: g.prompt) {
                close()
                head = g.item
                allowed = true
                out[item.key] = .folded
            } else {
                close()
                head = item
            }
            granted = nil
            for case .work(let w) in item.parts { calls.append(ToolCall(w)) }
        }
        close()
        return out
    }

    /// Whether an approval `prompt` asked for `work`'s call: its title, or its command (the preview
    /// a Bash call carries while its title is the brain's description), is in the prompt.
    static func asksFor(_ work: WorkRef, prompt: String) -> Bool {
        [work.title, work.preview].compactMap { $0 }.map { String($0.prefix(200)) }
            .contains { !$0.isEmpty && prompt.contains($0) }
    }

    /// The custom part of a tool row.
    static func toolPart(_ calls: [ToolCall], group: String, allowed: Bool = false) -> CustomPart {
        part(kind: toolKind, Tools(group: group, calls: calls, allowed: allowed ? true : nil))
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
        let failed = tools.calls.filter { $0.state == .failed }
        // A collapsed run says what failed, not only that something did: "1 of 4 failed: cmux tree --all".
        if let first = failed.first { return CmuxStrings.toolsFailedOf(failed.count, total: n, subject(first)) }
        return tools.calls.allSatisfy({ $0.kind == .command }) ? CmuxStrings.ranCommands(n) : CmuxStrings.usedTools(n)
    }

    /// What a call is, without its state's verb: the command, the human title, or the tool's title
    /// ("cmux tree --all", "Read Sources/App.swift").
    static func subject(_ call: ToolCall) -> String {
        if let human = call.humanTitle { return human }
        return call.kind == .command ? call.title : displayTitle(call.title)
    }

    /// A call's line as text ("Ran cmux tree --all", "Failed cmux tree --all", "Read Sources/App.swift").
    static func lineText(_ call: ToolCall) -> String {
        if let human = call.humanTitle { return human }
        guard call.kind == .command else { return displayTitle(call.title) }
        return commandFrame(call.state)(call.title)
    }

    /// The localized frame around a command for its state: "Running %@", "Ran %@", "Failed %@".
    static func commandFrame(_ state: ToolCall.State) -> (String) -> String {
        switch state {
        case .running: return CmuxStrings.toolRunning
        case .done: return CmuxStrings.toolRan
        case .failed: return CmuxStrings.toolFailed
        }
    }

    /// The words of a simple shell command, quotes removed (`'…'` and `"…"` stay one word), up to
    /// a `--` word; nil for a command this cannot read (an unclosed quote).
    static func words(_ command: String) -> [String]? {
        var out: [String] = [], word = "", quote: Character?, inWord = false
        for c in command {
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
                inWord = true
            } else if c == " " || c == "\t" {
                if inWord { out.append(word); word = ""; inWord = false }
            } else {
                word.append(c)
                inWord = true
            }
        }
        guard quote == nil else { return nil }
        if inWord { out.append(word) }
        return out
    }

    /// `cmux chief dispatch --agent codex --name "#12: fix" … -- '<task>'` as the user reads it:
    /// "Started Codex in “#12: fix”" (running: "Starting …", failed: "Couldn't start …"). Nil for
    /// other commands; the command stays in the tooltip and Copy.
    static func dispatchTitle(_ command: String, state: ToolCall.State) -> String? {
        guard command.hasPrefix("cmux chief dispatch"), let all = words(command), all.count >= 3,
              Array(all.prefix(3)) == ["cmux", "chief", "dispatch"] else { return nil }
        let flags = all.dropFirst(3).prefix { $0 != "--" }
        func value(_ name: String) -> String? {
            for (i, w) in flags.enumerated() {
                if w.hasPrefix(name + "=") { return String(w.dropFirst(name.count + 1)) }
                if w == name { return flags.dropFirst(i + 1).first }
            }
            return nil
        }
        guard let agent = value("--agent").map(agentName) else { return nil }
        let subject = value("--name").flatMap { $0.isEmpty ? nil : CmuxStrings.dispatchSubject(agent: agent, workspace: $0) } ?? agent
        switch state {
        case .running: return CmuxStrings.dispatchStarting(subject)
        case .done: return CmuxStrings.dispatchStarted(subject)
        case .failed: return CmuxStrings.dispatchFailed(subject)
        }
    }

    /// A dispatch's `--agent` as the user reads it: "Codex", "Claude Code", else as written.
    static func agentName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "codex": "Codex"
        case "claude": "Claude Code"
        default: agent
        }
    }

    /// `cmux chief memory add …`: the call that saves a memory note. Its row is hidden once it
    /// finished (`roles`): the note's own row ("Chief will remember: … · Undo") is its receipt.
    static func isMemorySave(_ command: String) -> Bool {
        // Leading `NAME=value` environment words are not the program.
        guard let all = words(command)?.drop(while: { $0.contains("=") && !$0.hasPrefix("-") }), all.count >= 4,
              let program = all.first, (program as NSString).lastPathComponent == "cmux" else { return false }
        return Array(all.dropFirst().prefix(3)) == ["chief", "memory", "add"]
    }

    /// A work part that saves a memory note: its title is the command, or (a Bash call whose title
    /// is the brain's description) its preview is.
    static func savesMemory(_ work: WorkRef) -> Bool {
        isMemorySave(work.title) || work.preview.map(isMemorySave) == true
    }

    /// A tool-only message whose every call is a finished memory save (`savesMemory`).
    static func isFinishedMemorySave(_ item: TranscriptItem) -> Bool {
        isToolOnly(item) && item.parts.allSatisfy {
            if case .work(let w) = $0 { w.status == .done && savesMemory(w) } else { false }
        }
    }

    /// The approval card's command as laid out: lines break only at spaces and after a "/" in a
    /// path, never at a hyphen inside a flag ("--wait-working"): each "-" is drawn as U+2011
    /// (non-breaking hyphen) and a zero-width space follows each "/". Layout only: Copy, the
    /// tooltip and VoiceOver read the command itself.
    static func wrappable(_ command: String) -> String {
        var out = ""
        out.reserveCapacity(command.count + 8)
        for c in command {
            switch c {
            case "-": out.append("\u{2011}")
            case "/": out.append("/\u{200B}")
            default: out.append(c)
            }
        }
        return out
    }

    /// Why a command asks, in one short line under the card's command: what it does when the
    /// policy asks for that reason ("Starts a coding agent"), else the words the allow list lacks.
    static func reason(for command: String) -> String? {
        guard let all = words(command), let program = all.first else { return nil }
        let sub = all.dropFirst().first
        if program == "cmux", sub == "chief", all.dropFirst(2).first == "dispatch" { return CmuxStrings.approvalReasonDispatch }
        if program == "cmux", sub == "vm" || sub == "cloud", all.dropFirst(2).first == "new" { return CmuxStrings.approvalReasonCloud }
        return CmuxStrings.approvalReasonNotAllowed(([program] + (sub.map { [$0] } ?? [])).joined(separator: " "))
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
        CustomRows.register(ChiefFailureRowProvider.shared)
        CustomRows.register(ChiefMemoryRowProvider.shared)
        CustomRows.register(ChiefStoppedRowProvider.shared)
    }
    private static var registered = false
}
