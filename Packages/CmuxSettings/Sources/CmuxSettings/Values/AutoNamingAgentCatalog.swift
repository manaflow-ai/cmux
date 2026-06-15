import Foundation

/// One selectable option for the workspace/tab auto-naming agent.
///
/// The naming agent is stored as an open string (the agent `slug`, or
/// ``AutoNamingAgentCatalog/autoSlug``) so it stays fully customizable — a
/// power user can name a custom agent in `~/.config/cmux/cmux.json` even if it
/// is not listed here. The Settings picker is populated from
/// ``AutoNamingAgentCatalog/agents`` and the bundled CLI consults the same
/// catalog when deciding which summarizer binary to invoke, so the two never
/// drift.
public struct AutoNamingAgentOption: Sendable, Hashable {
    /// CLI agent name; must match the hook `AgentHookDef.name` / the
    /// `<agent>` segment of `cmux hooks <agent> auto-name`.
    public let slug: String
    /// Brand display name shown in the picker (proper noun — not localized).
    public let displayName: String
    /// Whether cmux currently knows how to drive this agent as a summarizer.
    /// Unsupported agents are still selectable (the user asked for any agent),
    /// but naming falls back to each session's own agent.
    public let summarizerSupported: Bool

    public init(slug: String, displayName: String, summarizerSupported: Bool) {
        self.slug = slug
        self.displayName = displayName
        self.summarizerSupported = summarizerSupported
    }
}

/// Canonical, shared list of agents selectable for workspace/tab auto-naming.
///
/// Lives in `CmuxSettings` (imported by both the app's Settings UI and the
/// bundled `cmux` CLI) so the picker and the summarizer dispatch share one
/// source of truth for which agents exist and which can actually summarize.
/// lint:allow namespace-type — stateless, dependency-free agent data table shared verbatim by the Settings picker and the CLI summarizer dispatch.
public enum AutoNamingAgentCatalog {
    /// Sentinel meaning "name each session with its own agent" — the default,
    /// identical to the original auto-naming behavior.
    public static let autoSlug = "auto"

    /// Agents whose binary cmux knows how to invoke for a one-shot
    /// summarization. Keep in sync with the CLI summarizer dispatch.
    public static let supportedSlugs: Set<String> = [
        "claude", "codex", "grok", "opencode", "pi", "omp",
    ]

    /// All agents offered in the picker, in display order. Supported agents
    /// first, then the remainder (selectable but fall back to the session's own
    /// agent until cmux learns to drive them).
    public static let agents: [AutoNamingAgentOption] = [
        .init(slug: "claude", displayName: "Claude Code", summarizerSupported: true),
        .init(slug: "codex", displayName: "Codex", summarizerSupported: true),
        .init(slug: "grok", displayName: "Grok", summarizerSupported: true),
        .init(slug: "opencode", displayName: "OpenCode", summarizerSupported: true),
        .init(slug: "pi", displayName: "Pi", summarizerSupported: true),
        .init(slug: "omp", displayName: "OMP", summarizerSupported: true),
        .init(slug: "amp", displayName: "Amp", summarizerSupported: false),
        .init(slug: "cursor", displayName: "Cursor", summarizerSupported: false),
        .init(slug: "gemini", displayName: "Gemini", summarizerSupported: false),
        .init(slug: "kiro", displayName: "Kiro", summarizerSupported: false),
        .init(slug: "antigravity", displayName: "Antigravity", summarizerSupported: false),
        .init(slug: "rovodev", displayName: "Rovo Dev", summarizerSupported: false),
        .init(slug: "hermes-agent", displayName: "Hermes Agent", summarizerSupported: false),
        .init(slug: "copilot", displayName: "Copilot", summarizerSupported: false),
        .init(slug: "codebuddy", displayName: "CodeBuddy", summarizerSupported: false),
        .init(slug: "factory", displayName: "Factory", summarizerSupported: false),
        .init(slug: "qoder", displayName: "Qoder", summarizerSupported: false),
    ]

    /// Supported agents, in display order (picker "primary" group).
    public static var supportedAgents: [AutoNamingAgentOption] {
        agents.filter { $0.summarizerSupported }
    }

    /// Selectable-but-not-yet-driveable agents (picker "other" group).
    public static var otherAgents: [AutoNamingAgentOption] {
        agents.filter { !$0.summarizerSupported }
    }

    public static func option(forSlug slug: String) -> AutoNamingAgentOption? {
        agents.first { $0.slug == slug }
    }

    /// True only when cmux can drive `slug` as a summarizer. Custom/unknown
    /// slugs return false (they fall back to the session's own agent).
    public static func summarizerSupported(slug: String) -> Bool {
        supportedSlugs.contains(slug)
    }

    /// Display name for any slug, falling back to the raw slug for custom
    /// agents not in the catalog.
    public static func displayName(forSlug slug: String) -> String {
        option(forSlug: slug)?.displayName ?? slug
    }

    /// Outcome of resolving which agent should summarize a naming pass.
    public struct SummarizerDecision: Sendable, Equatable {
        /// The agent that should actually run the summarization.
        public let agent: String
        /// Non-nil when a supported override was chosen but its binary is
        /// missing, so we fell back to the session's own agent. Carries the
        /// chosen agent so the app can surface a "not installed" note.
        public let missingOverride: String?

        public init(agent: String, missingOverride: String?) {
            self.agent = agent
            self.missingOverride = missingOverride
        }
    }

    /// Pure decision for which agent summarizes a pass, given the user's
    /// override `chosen`, the session's own `sessionAgent`, and a binary-
    /// availability probe. Kept here (and dependency-injected) so it is unit
    /// testable without the CLI: `auto`/empty/the session itself/an unsupported
    /// or uninstalled override all collapse to `sessionAgent`, so naming never
    /// breaks; a supported-but-missing override is reported via
    /// ``SummarizerDecision/missingOverride``.
    public static func resolveSummarizer(
        chosen: String?,
        sessionAgent: String,
        isInstalled: (String) -> Bool
    ) -> SummarizerDecision {
        let chosen = chosen?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !chosen.isEmpty, chosen != autoSlug, chosen != sessionAgent else {
            return SummarizerDecision(agent: sessionAgent, missingOverride: nil)
        }
        guard summarizerSupported(slug: chosen) else {
            return SummarizerDecision(agent: sessionAgent, missingOverride: nil)
        }
        guard isInstalled(chosen) else {
            return SummarizerDecision(agent: sessionAgent, missingOverride: chosen)
        }
        return SummarizerDecision(agent: chosen, missingOverride: nil)
    }
}
