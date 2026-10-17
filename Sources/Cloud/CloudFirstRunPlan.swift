import CmuxFoundation
import Foundation

// The pure half of the first-run tour ("Start your first cloud agent"): which
// agent, where its key comes from, which repository, which machine, how far
// `cmux vm clone` got, and how long each phase took. No app objects, so every
// rule here is unit tested; ``CloudFirstRunModel`` drives it.

/// The agents the tour offers. Raw values are `cmux vm clone --agent` names.
enum CloudFirstRunAgent: String, CaseIterable, Equatable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude:
            return String(localized: "machines.agent.claude", defaultValue: "Claude Code")
        case .codex:
            return String(localized: "machines.agent.codex", defaultValue: "Codex")
        }
    }

    /// Cloud Secrets names that count as this agent's own key. The first one is
    /// the name the tour's key field saves.
    var keyNames: [String] {
        switch self {
        case .claude: return ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"]
        case .codex: return ["OPENAI_API_KEY"]
        }
    }

    var savedKeyName: String { keyNames[0] }

    /// The CodeRouter account type that runs this agent on cmux's model router
    /// with no key of the user's (`coderouter accounts --json` `provider`).
    var coderouterProviderID: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    /// Where to get a key, linked beside the field.
    var keyURL: URL {
        switch self {
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .codex: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    /// The provider's own noun, with the article that is right for it.
    var getKeyLabel: String {
        switch self {
        case .claude:
            return String(localized: "cloud.firstRun.key.get.anthropic", defaultValue: "Get an API key from Anthropic")
        case .codex:
            return String(localized: "cloud.firstRun.key.get.openai", defaultValue: "Get an API key from OpenAI")
        }
    }

    var subscriptionLabel: String {
        switch self {
        case .claude:
            return String(localized: "cloud.firstRun.key.subscription.claude", defaultValue: "Use my Claude subscription")
        case .codex:
            return String(localized: "cloud.firstRun.key.subscription.codex", defaultValue: "Use my ChatGPT subscription")
        }
    }
}

/// Where the chosen agent's credentials come from on the machine. The order is
/// the machine's own precedence (`CloudSecretsProviderRouting`): a key of the
/// user's always wins, the team's model-router account applies only without one.
enum CloudFirstRunKeySource: Equatable, Sendable {
    /// A key already in Cloud Secrets; nothing to do.
    case vault(name: String)
    /// The team has a subscription account on cmux's model router for this
    /// agent, so the machine needs no key at all (the zero-step default).
    case teamRouter
    /// The person typed a key in this tour; it is saved when they press Go.
    case typed
    /// No key anywhere: the step asks for one.
    case missing

    var isReady: Bool { self != .missing }

    /// Typed text that can be a key: one line, no spaces, not trivially short.
    /// The vault validates again on save; this only gates the Go button.
    static func isPlausibleKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 8 && !trimmed.contains(where: \.isWhitespace)
    }

    static func resolve(
        agent: CloudFirstRunAgent,
        vaultNames: Set<String>,
        activeTeamProviders: Set<String>,
        typedKey: String
    ) -> CloudFirstRunKeySource {
        if let name = agent.keyNames.first(where: vaultNames.contains) { return .vault(name: name) }
        if activeTeamProviders.contains(agent.coderouterProviderID) { return .teamRouter }
        if isPlausibleKey(typedKey) { return .typed }
        return .missing
    }
}

/// The repository field: what the tour hands to `cmux vm clone`.
enum CloudFirstRunRepo {
    /// A tiny, stable public repository (an HTML page, a stylesheet and a
    /// README) that clones in well under a second and needs no token.
    static let sample = "octocat/Spoon-Knife"

    /// The repository `raw` names, with the Open Repository sheet's and
    /// `cmux vm clone`'s own rules (``CloudOpenRepositoryReference``): owner/repo,
    /// GitHub URLs with `/tree/<branch>`, scp-style and other git URLs. `.`
    /// (there is no local folder here) and URLs carrying credentials are refused.
    static func reference(_ raw: String) -> CloudOpenRepositoryReference? {
        try? CloudOpenRepositoryReference.parse(raw).get()
    }

    /// The prefilled first task: read-only, so a first run never surprises
    /// anyone with edits, and concrete, so the agent does something visible.
    static var defaultPrompt: String {
        String(
            localized: "cloud.firstRun.prompt.default",
            defaultValue: "Explain what this repository does in a few sentences, then suggest one small improvement. Don\u{2019}t change any files yet."
        )
    }

    /// Longest first task the tour sends (it rides argv to the machine).
    static let maxPromptLength = 2_000
}

/// A machine the tour can run on.
struct CloudFirstRunMachine: Equatable, Sendable {
    let id: String
    let name: String
    /// Paused: `vm clone` wakes it first (a couple of seconds), which is
    /// still faster than a new machine and keeps the person's files.
    var needsWake = false

    /// Statuses that take a `vm clone` right away.
    static let readyStatuses: Set<String> = ["running", "ready"]
    /// Statuses `vm clone --machine` wakes before it clones.
    static let wakeableStatuses: Set<String> = ["paused", "standby"]

    /// The machine to reuse from a fleet read: the newest ready one, else the
    /// newest paused one, never one being deleted. nil means the tour starts
    /// a new machine.
    static func reusable(
        from machines: [(id: String, status: String, name: String, createdAt: Int64)],
        hiddenIDs: Set<String>
    ) -> CloudFirstRunMachine? {
        let live = machines.filter { !hiddenIDs.contains($0.id) }
        func newest(_ statuses: Set<String>) -> (id: String, status: String, name: String, createdAt: Int64)? {
            live.filter { statuses.contains($0.status.lowercased()) }.max { $0.createdAt < $1.createdAt }
        }
        if let ready = newest(readyStatuses) {
            return CloudFirstRunMachine(id: ready.id, name: ready.name)
        }
        if let paused = newest(wakeableStatuses) {
            return CloudFirstRunMachine(id: paused.id, name: paused.name, needsWake: true)
        }
        return nil
    }
}

/// The `cmux vm clone` invocation for Go.
enum CloudFirstRunCommand {
    /// Arguments after `cmux`. The prompt follows `-- --`: the first `--` ends
    /// `vm clone`'s own flags and the second is handed to the agent, so it
    /// starts interactively with the task as its first message instead of the
    /// one-shot form a bare prompt selects (`vmAgentArgv`).
    static func cloneArguments(
        repo: CloudOpenRepositoryReference,
        machineID: String,
        agent: CloudFirstRunAgent,
        prompt: String
    ) -> [String] {
        var arguments = ["vm", "clone", repo.cloneArgument]
        if let branch = repo.branch { arguments += ["--branch", branch] }
        // The tour is an explicit user action even though its CLI process is
        // launched in the background; carry focus intent through so the new
        // Cloud workspace and agent terminal are selected when it succeeds.
        arguments += ["--machine", machineID, "--agent", agent.rawValue, "--focus", "--json"]
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty {
            arguments += ["--", "--", String(task.prefix(CloudFirstRunRepo.maxPromptLength))]
        }
        return arguments
    }
}

/// How far a running `cmux vm clone` got, from the phase lines it writes to
/// stderr (`[cmux vm clone] <label> 1.2s — <detail>`). The label is localized,
/// so only the prefix is read; the CLI's phase order is fixed.
struct CloudFirstRunCloneProgress: Equatable {
    static let linePrefix = "[cmux vm clone] "

    private var pending = ""
    private(set) var finishedPhases = 0

    mutating func consume(_ chunk: String) {
        pending += chunk
        while let newline = pending.firstIndex(of: "\n") {
            let line = pending[..<newline]
            pending = String(pending[pending.index(after: newline)...])
            if line.hasPrefix(Self.linePrefix) { finishedPhases += 1 }
        }
    }

    /// What the clone is doing now, for the agent step's detail line. Phases:
    /// machine, secrets, clone, workspace, then (setup and) agent.
    func detail(repo: String, agent: CloudFirstRunAgent) -> String {
        switch finishedPhases {
        case 0:
            return String(localized: "cloud.firstRun.clone.connecting", defaultValue: "Connecting to the machine\u{2026}")
        case 1:
            return String(localized: "cloud.firstRun.clone.secrets", defaultValue: "Sending your keys\u{2026}")
        case 2:
            return String(
                format: String(localized: "cloud.firstRun.clone.cloning", defaultValue: "Cloning %@\u{2026}"),
                repo
            )
        case 3:
            return String(localized: "cloud.firstRun.clone.workspace", defaultValue: "Opening the workspace\u{2026}")
        default:
            return String(
                format: String(localized: "cloud.firstRun.clone.agent", defaultValue: "Starting %@\u{2026}"),
                agent.displayName
            )
        }
    }
}

/// What a finished `cmux vm clone --json` reported.
struct CloudFirstRunCloneResult: Equatable {
    var agentTerminalID: String?
    var workspaceID: String?
    /// Phase key (`machine`, `secrets`, `clone`, `workspace`, `setup`, `agent`) → seconds.
    var timings: [String: Double]
    var missingSecrets: [String]

    /// Finds the JSON object in the run's output (stdout and stderr together):
    /// the first line opening a `{` through the last line closing one.
    static func parse(output: String) -> CloudFirstRunCloneResult? {
        let lines = output.components(separatedBy: "\n")
        for start in lines.indices where lines[start].hasPrefix("{") {
            for end in lines.indices.reversed() where end >= start && lines[end].trimmingCharacters(in: .whitespaces).hasSuffix("}") {
                let text = lines[start...end].joined(separator: "\n")
                guard let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                var timings: [String: Double] = [:]
                for (key, value) in object["timings"] as? [String: Any] ?? [:] {
                    if let seconds = (value as? NSNumber)?.doubleValue { timings[key] = seconds }
                }
                return CloudFirstRunCloneResult(
                    agentTerminalID: object["agent_terminal_id"] as? String,
                    workspaceID: object["workspace_id"] as? String,
                    timings: timings,
                    missingSecrets: object["missing_secrets"] as? [String] ?? []
                )
            }
        }
        return nil
    }
}

/// The one recovery a failed phase offers. Never a dead end.
enum CloudFirstRunRecovery: String, Equatable, Sendable {
    /// Start the machine again.
    case retryMachine
    /// Run the clone again with the same inputs.
    case retryClone
    /// The repository needs a GitHub token: open Cloud Secrets.
    case addGitHubToken
    /// Put the key field back so the person can fix the key.
    case editKey

    var title: String {
        switch self {
        case .retryMachine, .retryClone:
            return String(localized: "cloud.firstRun.recovery.tryAgain", defaultValue: "Try Again")
        case .addGitHubToken:
            return String(localized: "cloud.firstRun.recovery.addToken", defaultValue: "Add a GitHub Token\u{2026}")
        case .editKey:
            return String(localized: "cloud.firstRun.recovery.editKey", defaultValue: "Fix the Key")
        }
    }
}

/// A failed phase: one line of reason and its recovery.
struct CloudFirstRunFailure: Error, Equatable, Sendable {
    let reason: String
    let recovery: CloudFirstRunRecovery

    /// The reason a failed clone gives, read from its output: the last line
    /// that is not a phase line or JSON, without an `Error:` prefix.
    static func clone(output: String, status: Int32) -> CloudFirstRunFailure {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(CloudFirstRunCloneProgress.linePrefix) && !$0.hasPrefix("{") && !$0.hasPrefix("}") && !$0.hasPrefix("\"") }
        let lowered = output.lowercased()
        let needsToken = lowered.contains("repository not found")
            || lowered.contains("could not read username")
            || lowered.contains("authentication failed")
            || lowered.contains("gh_token")
        var headline = lines.last ?? ""
        for prefix in ["Error: ", "error: "] where headline.hasPrefix(prefix) {
            headline = String(headline.dropFirst(prefix.count))
        }
        if headline.count > 200 { headline = String(headline.prefix(200)) + "\u{2026}" }
        if needsToken {
            return CloudFirstRunFailure(
                reason: String(
                    localized: "cloud.firstRun.failure.private",
                    defaultValue: "The machine couldn\u{2019}t read that repository. It may be private or misspelled."
                ),
                recovery: .addGitHubToken
            )
        }
        if headline.isEmpty {
            headline = String(
                format: String(localized: "cloud.firstRun.failure.exit", defaultValue: "cmux vm clone stopped with status %ld."),
                Int(status)
            )
        }
        return CloudFirstRunFailure(reason: headline, recovery: .retryClone)
    }
}

/// Wall-clock marks for one tour, measured from the moment it opened. Local
/// debug log only: the log line carries durations and phase names, never a
/// key, a repository or a prompt.
struct CloudFirstRunTimeline: Equatable {
    enum Mark: String, CaseIterable, Sendable {
        case keyReady = "key"
        case machineReady = "machine"
        case go
        case agentStarted = "agent"
        case failed
    }

    let openedAt: Date
    private(set) var marks: [Mark: Date] = [:]

    init(openedAt: Date) {
        self.openedAt = openedAt
    }

    /// Records `mark` once; the first time wins (a retry keeps the original).
    mutating func record(_ mark: Mark, at date: Date) {
        if marks[mark] == nil { marks[mark] = date }
    }

    mutating func clear(_ mark: Mark) {
        marks[mark] = nil
    }

    /// Seconds from opening to `mark`.
    func seconds(_ mark: Mark) -> Double? {
        marks[mark].map { $0.timeIntervalSince(openedAt) }
    }

    /// The live timer: runs from opening until the agent started.
    func elapsed(now: Date) -> TimeInterval {
        max(0, (marks[.agentStarted] ?? now).timeIntervalSince(openedAt))
    }

    var isFinished: Bool { marks[.agentStarted] != nil }

    /// `m:ss` for the header timer.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// `12.3 s` beside a finished step.
    static func duration(_ seconds: Double) -> String {
        String(
            format: String(localized: "cloud.firstRun.duration", defaultValue: "%.1f s"),
            seconds
        )
    }

    /// One local debug log line: `cloud.firstRun.timing key=0.0 machine=14.2 go=9.8 agent=38.4 clone.machine=0.3 …`.
    func logLine(cloneTimings: [String: Double] = [:]) -> String {
        var parts = ["cloud.firstRun.timing"]
        for mark in Mark.allCases {
            if let seconds = seconds(mark) { parts.append("\(mark.rawValue)=\(String(format: "%.1f", seconds))") }
        }
        for key in cloneTimings.keys.sorted() {
            parts.append("clone.\(key)=\(String(format: "%.1f", cloneTimings[key] ?? 0))")
        }
        return parts.joined(separator: " ")
    }
}
