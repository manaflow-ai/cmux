import Foundation

/// An immutable validated catalog reused by process recognition and screen classification.
public struct AgentTerminalProfileCatalog: Sendable {
    /// Profiles in stable declaration order.
    public let profiles: [AgentTerminalFamilyProfile]

    private let byID: [String: AgentTerminalFamilyProfile]
    private let byHint: [String: AgentTerminalFamilyProfile]
    private let byExecutable: [String: AgentTerminalFamilyProfile]

    /// Validates a replacement catalog outside terminal-update paths.
    ///
    /// Invalid input returns `nil`, allowing a caller to retain its previous catalog.
    public init?(profiles: [AgentTerminalFamilyProfile]) {
        guard !profiles.isEmpty else { return nil }
        var validatedProfiles: [AgentTerminalFamilyProfile] = []
        var byID: [String: AgentTerminalFamilyProfile] = [:]
        var byHint: [String: AgentTerminalFamilyProfile] = [:]
        var executableOwners: [String: String] = [:]
        for rawProfile in profiles {
            guard let profile = Self.validatedProfile(rawProfile) else { return nil }
            let id = profile.id
            guard byID[id] == nil else { return nil }
            for executable in profile.executableBasenames {
                guard executableOwners[executable] == nil else { return nil }
                executableOwners[executable] = id
            }
            validatedProfiles.append(profile)
            byID[id] = profile
            for hint in profile.hintAliases.union([profile.id]) {
                let normalizedHint = Self.normalized(hint)
                guard !normalizedHint.isEmpty else { return nil }
                if let existing = byHint[normalizedHint], existing.id != profile.id { return nil }
                byHint[normalizedHint] = profile
            }
        }
        self.profiles = validatedProfiles
        self.byID = byID
        self.byHint = byHint
        self.byExecutable = Dictionary(uniqueKeysWithValues: validatedProfiles.flatMap { profile in
            profile.executableBasenames.map { ($0, profile) }
        })
    }

    /// Returns the profile for a canonical identifier.
    public func profile(id: String) -> AgentTerminalFamilyProfile? {
        byID[Self.normalized(id)]
    }

    /// Returns the profile declared by a scoped wrapper hint.
    public func profile(hint: String) -> AgentTerminalFamilyProfile? {
        byHint[Self.normalized(hint)]
    }

    /// Returns the unique profile that owns an executable basename.
    func profile(executableBasename: String) -> AgentTerminalFamilyProfile? {
        byExecutable[Self.normalizedNeedle(executableBasename)]
    }

    /// Returns profiles that publish the supplied cmux lifecycle key.
    public func profiles(statusKey: String) -> [AgentTerminalFamilyProfile] {
        profiles.filter { $0.statusKey == statusKey }
    }

    /// The built-in 21-family compatibility catalog plus cmux's existing extras.
    public static let builtIn = AgentTerminalProfileCatalog(profiles: builtInProfiles)!

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func validatedProfile(_ raw: AgentTerminalFamilyProfile) -> AgentTerminalFamilyProfile? {
        let id = normalized(raw.id)
        let statusKey = raw.statusKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = raw.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let executables = Set(raw.executableBasenames.map(normalizedNeedle))
        guard !id.isEmpty, !statusKey.isEmpty, !displayName.isEmpty,
              !executables.isEmpty, !executables.contains("") else { return nil }
        guard let arguments = normalizedNeedles(raw.argumentNeedles),
              let aliases = normalizedAliases(raw.hintAliases),
              let idle = normalizedNeedles(raw.idleNeedles),
              let working = normalizedEvidenceGroups(raw.workingEvidenceGroups),
              let blocked = normalizedEvidenceGroups(raw.blockedEvidenceGroups, minimumCount: 2),
              let blockedExactLines = normalizedNeedles(raw.blockedExactLines),
              let history = normalizedNeedles(raw.historyViewNeedles) else { return nil }
        return AgentTerminalFamilyProfile(
            id: id,
            statusKey: statusKey,
            sessionProviderID: raw.sessionProviderID,
            displayName: displayName,
            lifecycleAuthoritative: raw.lifecycleAuthoritative,
            executableBasenames: executables,
            argumentNeedles: arguments,
            hintAliases: aliases,
            idleNeedles: idle,
            workingEvidenceGroups: working,
            blockedEvidenceGroups: blocked,
            blockedExactLines: blockedExactLines,
            historyViewNeedles: history
        )
    }

    private static func normalizedNeedle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedNeedles(_ raw: [String]) -> [String]? {
        let normalized = raw.map(normalizedNeedle)
        return normalized.contains("") ? nil : normalized
    }

    private static func normalizedAliases(_ raw: Set<String>) -> Set<String>? {
        let normalized = Set(raw.map(normalized))
        return normalized.contains("") ? nil : normalized
    }

    private static func normalizedEvidenceGroups(_ raw: [[String]], minimumCount: Int = 1) -> [[String]]? {
        var result: [[String]] = []
        for group in raw {
            guard group.count >= minimumCount, let normalized = normalizedNeedles(group) else { return nil }
            result.append(normalized)
        }
        return result
    }

    private static let commonHistoryNeedles = ["conversation history", "transcript viewer", "session history"]
    private static let commonBlockedEvidenceGroups = [
        ["requires approval", "yes", "no"], ["approval required", "approve"],
        ["would you like to run the following command", "yes", "no"],
        ["do you want to proceed", "yes", "no"],
        ["session may have expired", "/login"],
    ]
    private static let commonBlockedExactLines = [
        "waiting for approval",
        "enter your api key",
        "api key required",
        "authentication required",
        "type /login to re-authenticate",
    ]

    private static let builtInProfiles: [AgentTerminalFamilyProfile] = [
        profile("pi", "Pi", authoritative: true, executables: ["pi", "pi-coding-agent"], arguments: ["pi-coding-agent"], idle: ["pi", "context"], working: [["working..."], ["working…"]]),
        profile("omp", "OMP", authoritative: true, executables: ["omp"], arguments: ["oh-my-pi"], idle: ["context", "reasoning"], working: [["working..."], ["working…"]]),
        profile("copilot", "GitHub Copilot CLI", executables: ["copilot", "github-copilot-cli"], arguments: ["github copilot", "@github/copilot"], idle: ["what would you like"], working: [["esc to interrupt"]]),
        profile("devin", "Devin CLI", executables: ["devin", "devin-cli"], arguments: ["devin-cli"], idle: ["ask devin"], working: [["esc to interrupt"]]),
        profile("kimi", "Kimi Code CLI", authoritative: true, executables: ["kimi", "kimi-cli", "kimi-code"], arguments: ["kimi-code", "kimi code"], idle: ["input"], working: [["esc to interrupt"]], blocked: [["[enter]", "upgrade now", "[q]", "not now"]]),
        profile("hermes-agent", "Hermes Agent", authoritative: true, executables: ["hermes", "hermes-agent"], arguments: ["hermes-agent"], idle: ["hermes"], working: [["executing tool"]]),
        profile("qoder", "Qoder CLI", executables: ["qoder", "qodercli"], arguments: ["qodercli"], idle: ["ask qoder"], working: [["esc to interrupt"]]),
        profile("droid", "Droid", statusKey: "factory", executables: ["droid"], arguments: ["factory.ai", "factory-cli"], idle: ["ask droid"], working: [["esc to interrupt"]]),
        profile("opencode", "OpenCode", authoritative: true, executables: ["opencode", "opencode-ai", "open-code"], arguments: ["opencode"], idle: ["ask anything"], working: [["esc interrupt"]]),
        profile("kilo", "Kilo Code CLI", authoritative: true, executables: ["kilo", "kilo-code"], arguments: ["kilo-code"], idle: ["ask anything"], working: [["esc to interrupt"]]),
        profile("mastracode", "MastraCode", authoritative: true, executables: ["mastracode", "mastra-code"], arguments: ["mastracode", "mastra-code"], idle: ["mastra"], working: [["esc to interrupt"]]),
        profile("claude-code", "Claude Code", statusKey: "claude_code", sessionProviderID: "claude", executables: ["claude", "claude-code", "claude_code"], arguments: ["@anthropic-ai/claude-code", "claude-code", "/claude/versions/"], aliases: ["claude"], idle: ["try \"", "claude code"], working: [["esc to interrupt"]]),
        profile("codex", "Codex", executables: ["codex"], arguments: ["@openai/codex"], idle: ["ask codex", "write tests for"], working: [["working ("], ["esc to interrupt"]]),
        profile("cursor-agent", "Cursor Agent CLI", statusKey: "cursor", executables: ["cursor-agent"], arguments: ["cursor-agent"], aliases: ["cursor"], idle: ["ask cursor", "cursor agent"], working: [["running", "tokens"]]),
        profile("amp", "Amp", executables: ["amp"], arguments: ["@ampcode"], idle: ["ask amp"], working: [["esc to interrupt"]]),
        profile("grok", "Grok CLI", executables: ["grok", "grok-macos-aarch64", "grok-macos-aarch"], arguments: ["@xai/grok", "grok-build"], idle: ["grok", "model"], working: [["starting session"], ["queued task"]]),
        profile("antigravity", "Antigravity CLI", executables: ["antigravity", "agy"], arguments: ["antigravity-cli"], aliases: ["agy"], idle: ["ask anything"], working: [["esc to interrupt"]]),
        profile("kiro", "Kiro CLI", executables: ["kiro", "kiro-cli"], arguments: ["kiro-cli"], idle: ["ask kiro"], working: [["esc to interrupt"]]),
        profile("maki", "Maki", executables: ["maki"], arguments: ["maki-cli"], idle: ["ask maki"], working: [["esc to interrupt"]]),
        profile(
            "gemini",
            "Gemini CLI",
            executables: ["gemini"],
            arguments: ["@google/gemini-cli", "gemini-cli"],
            idle: ["type your message", "gemini"],
            working: [["esc to cancel"]],
            blocked: [["enter gemini api key", "paste your api key here"]]
        ),
        profile("cline", "Cline", executables: ["cline", "cline-cli"], arguments: ["cline-cli"], idle: ["ask cline"], working: [["esc to interrupt"]]),
        // Existing cmux-only families remain recognized.
        profile("campfire", "Campfire", authoritative: true, executables: ["campfire"], arguments: ["session/bin/campfire", "session/dist/campfire"], idle: ["campfire"], working: [["esc to interrupt"]]),
        profile("rovodev", "Rovo Dev", authoritative: true, executables: ["rovodev"], arguments: ["rovodev"], aliases: ["rovo"], idle: ["ask rovo"], working: [["esc to interrupt"]]),
        profile("codebuddy", "CodeBuddy", authoritative: true, executables: ["codebuddy"], arguments: ["codebuddy"], idle: ["codebuddy"], working: [["esc to interrupt"]]),
        profile("factory", "Factory", authoritative: true, executables: ["factory"], arguments: ["factory"], idle: ["factory"], working: [["esc to interrupt"]]),
        profile("ollama", "Ollama", authoritative: true, executables: ["ollama"], arguments: ["ollama run"], idle: [">>>", "send a message"], working: [["thinking"], ["generating"]]),
    ]

    private static func profile(
        _ id: String,
        _ displayName: String,
        statusKey: String? = nil,
        sessionProviderID: String? = nil,
        authoritative: Bool = false,
        executables: Set<String>,
        arguments: [String],
        aliases: Set<String> = [],
        idle: [String],
        working: [[String]],
        blocked: [[String]] = []
    ) -> AgentTerminalFamilyProfile {
        AgentTerminalFamilyProfile(
            id: id,
            statusKey: statusKey ?? id,
            sessionProviderID: sessionProviderID ?? statusKey ?? id,
            displayName: displayName,
            lifecycleAuthoritative: authoritative,
            executableBasenames: executables,
            argumentNeedles: arguments,
            hintAliases: aliases,
            idleNeedles: idle,
            workingEvidenceGroups: working,
            blockedEvidenceGroups: commonBlockedEvidenceGroups + blocked,
            blockedExactLines: commonBlockedExactLines,
            historyViewNeedles: commonHistoryNeedles
        )
    }
}
