internal import Foundation

/// Exhaustive identity shared by hook installation and lifecycle reconciliation.
public nonisolated enum BuiltInAgentIntegration: String, CaseIterable, Hashable, Sendable {
    /// OpenAI Codex.
    case codex
    /// Grok CLI.
    case grok
    /// OpenCode.
    case opencode
    /// Pi.
    case pi
    /// Oh My Pi.
    case omp
    /// Campfire.
    case campfire
    /// Amp.
    case amp
    /// Cursor CLI.
    case cursor
    /// Gemini CLI.
    case gemini
    /// Kiro CLI.
    case kiro
    /// Antigravity.
    case antigravity
    /// Rovo Dev.
    case rovodev
    /// Hermes Agent.
    case hermesAgent = "hermes-agent"
    /// GitHub Copilot CLI.
    case copilot
    /// CodeBuddy.
    case codebuddy
    /// Factory.
    case factory
    /// Qoder.
    case qoder
    /// Kimi Code.
    case kimi
    /// Claude Code.
    case claude

    /// Built-ins installed through the generic hook catalog.
    public static var genericHookIntegrations: [Self] {
        allCases.filter { $0 != .claude }
    }

    /// Creates an integration from its normalized Feed source name.
    ///
    /// - Parameter feedSourceName: The source name supplied by an agent hook.
    public init?(feedSourceName: String) {
        let normalized = feedSourceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.init(rawValue: normalized)
    }

    /// The stable Feed source name for the integration.
    public var feedSourceName: String {
        rawValue
    }

    /// The sidebar lifecycle status key owned by the integration.
    public var statusKey: String {
        switch self {
        case .claude:
            "claude_code"
        case .amp, .antigravity, .campfire, .codebuddy, .codex, .copilot,
             .cursor, .factory, .gemini, .grok, .hermesAgent, .kiro, .kimi,
             .omp, .opencode, .pi, .qoder, .rovodev:
            rawValue
        }
    }

    /// The lifecycle identity that owns this integration's process generation.
    public var lifecycleProcessOwnershipScope: AgentLifecycleProcessOwnershipScope {
        switch self {
        case .amp, .claude:
            .sharedProcess
        case .antigravity, .campfire, .codebuddy, .codex, .copilot, .cursor,
             .factory, .gemini, .grok, .hermesAgent, .kiro, .kimi, .omp,
             .opencode, .pi, .qoder, .rovodev:
            .session
        }
    }

    /// The user-facing integration name.
    public var displayName: String {
        switch self {
        case .amp: "Amp"
        case .antigravity: "Antigravity"
        case .campfire: "Campfire"
        case .claude: "Claude Code"
        case .codebuddy: "CodeBuddy"
        case .codex: "Codex"
        case .copilot: "Copilot"
        case .cursor: "Cursor"
        case .factory: "Factory"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .hermesAgent: "Hermes Agent"
        case .kiro: "Kiro"
        case .kimi: "Kimi Code"
        case .omp: "OMP"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        case .qoder: "Qoder"
        case .rovodev: "Rovo Dev"
        }
    }

    /// The evidence policy required before a turn may settle.
    public var turnSettlementPolicy: AgentTurnSettlementPolicy {
        switch self {
        case .amp:
            .requiresSettledBoundary
        case .antigravity, .campfire, .claude, .codebuddy, .codex, .copilot,
             .cursor, .factory, .gemini, .grok, .hermesAgent, .kiro, .kimi,
             .omp, .opencode, .pi, .qoder, .rovodev:
            .turnEndWhenNoBackgroundWork
        }
    }

    /// The explicit approval-detection contract for the integration.
    public var approvalDetectionMechanism: AgentApprovalDetectionMechanism {
        switch self {
        case .codebuddy, .copilot, .factory, .gemini, .grok, .kiro, .kimi,
             .qoder:
            .sideEffectingToolStartInference
        case .amp, .cursor:
            .nativePostPolicyObserver
        case .codex:
            .nativeApprovalReviewer
        case .antigravity, .campfire, .claude, .hermesAgent, .omp,
             .opencode, .pi, .rovodev:
            .dedicatedPermissionEvent
        }
    }
}
