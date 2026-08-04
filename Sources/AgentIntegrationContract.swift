import Foundation

/// Exhaustive identity shared by hook installation, Feed approval semantics,
/// sidebar lifecycle keys, and turn settlement.
///
/// Adding a built-in agent requires adding one enum case and satisfying every
/// exhaustive switch below. Unknown third-party Feed sources remain neutral,
/// but a built-in source can no longer silently fall out of one hand-maintained
/// registry while appearing in another.
enum BuiltInAgentIntegration: String, CaseIterable, Hashable, Sendable {
    case codex
    case grok
    case opencode
    case pi
    case omp
    case campfire
    case amp
    case cursor
    case gemini
    case kiro
    case antigravity
    case rovodev
    case hermesAgent = "hermes-agent"
    case copilot
    case codebuddy
    case factory
    case qoder
    case kimi
    case claude

    /// Built-ins installed through the generic `AgentHookDef` catalog.
    /// Claude remains on its bespoke hook installer.
    static var genericHookIntegrations: [Self] {
        allCases.filter { $0 != .claude }
    }

    init?(feedSourceName: String) {
        let normalized = feedSourceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.init(rawValue: normalized)
    }

    var feedSourceName: String {
        rawValue
    }

    var statusKey: String {
        switch self {
        case .claude:
            "claude_code"
        case .amp, .antigravity, .campfire, .codebuddy, .codex, .copilot,
             .cursor, .factory, .gemini, .grok, .hermesAgent, .kiro, .kimi,
             .omp, .opencode, .pi, .qoder, .rovodev:
            rawValue
        }
    }

    var displayName: String {
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

    var turnSettlementPolicy: AgentTurnSettlementPolicy {
        switch self {
        case .amp:
            .requiresSettledBoundary
        case .antigravity, .campfire, .claude, .codebuddy, .codex, .copilot,
             .cursor, .factory, .gemini, .grok, .hermesAgent, .kiro, .kimi,
             .omp, .opencode, .pi, .qoder, .rovodev:
            .turnEndWhenNoBackgroundWork
        }
    }

    /// The required approval-detection mechanism for this integration.
    ///
    /// This exhaustive contract prevents a built-in from being added with
    /// telemetry-only defaults. Every case must provide either a dedicated
    /// permission event, conservative tool-start inference, or a trustworthy
    /// post-policy native observer.
    var approvalDetectionMechanism: AgentApprovalDetectionMechanism {
        switch self {
        case .codebuddy, .copilot, .factory, .gemini, .grok, .kiro, .kimi,
             .qoder:
            .sideEffectingToolStartInference
        case .amp, .cursor:
            .nativePostPolicyObserver
        case .antigravity, .campfire, .claude, .codex, .hermesAgent, .omp,
             .opencode, .pi, .rovodev:
            .dedicatedPermissionEvent
        }
    }
}

enum AgentApprovalDetectionMechanism: Equatable, Sendable {
    /// The adapter emits a distinct permission/approval request. Generic
    /// tool-start events remain telemetry.
    case dedicatedPermissionEvent
    /// The runtime has no distinct approval event, so side-effecting
    /// tool-starts conservatively surface a permission wait.
    case sideEffectingToolStartInference
    /// A source adapter observes the agent's decision after native policy
    /// evaluation and publishes attention only when it confirms a real wait.
    case nativePostPolicyObserver
}

enum AgentAttentionWireValidation {
    static func opaqueIdentifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
        !value.isEmpty,
        value.utf8.count <= 160,
        value.unicodeScalars.allSatisfy({
            $0.isASCII
                && !$0.properties.isWhitespace
                && !CharacterSet.controlCharacters.contains($0)
        }) else {
            return nil
        }
        return value
    }
}
