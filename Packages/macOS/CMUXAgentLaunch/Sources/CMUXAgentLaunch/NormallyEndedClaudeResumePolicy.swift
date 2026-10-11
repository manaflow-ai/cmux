import Foundation

/// Decides when a completed Claude session may enter automatic restore.
///
/// Claude hook snapshots carry an explicit prompt-turn marker. An explicit
/// `false` proves that no deferred tool continuation is waiting. A missing
/// marker is admitted only when persisted process state independently proves
/// that the agent had already stopped.
public struct NormallyEndedClaudeResumePolicy: Sendable {
    /// The normalized kind used by Claude Code hook bindings.
    public static let claudeKind = "claude"

    /// The hook source required for automatic resume admission.
    public static let agentHookSource = "agent-hook"

    /// The evidence needed to admit a normally completed Claude session.
    public struct AdmissionEvidence: Sendable {
        /// The persisted agent kind.
        public var agentKind: String
        /// The persisted agent checkpoint identity.
        public var agentSessionID: String
        /// Whether the captured session still had an active prompt turn.
        public var hadActivePromptTurn: Bool?
        /// Whether the agent process was running when the snapshot was saved.
        /// A value of `false` is the only process-state evidence that can
        /// disambiguate a missing prompt-turn marker.
        public var wasAgentRunning: Bool?
        /// The binding's persisted agent kind.
        public var bindingKind: String?
        /// The binding's checkpoint identity.
        public var bindingSessionID: String?
        /// The binding publisher source.
        public var bindingSource: String?
        /// Whether automatic resume was enabled for the binding.
        public var autoResume: Bool?

        /// Creates captured admission evidence.
        ///
        /// - Parameters:
        ///   - agentKind: The persisted agent kind.
        ///   - agentSessionID: The persisted agent checkpoint identity.
        ///   - hadActivePromptTurn: The explicit prompt-turn marker, when present.
        ///   - wasAgentRunning: Persisted process liveness at snapshot time.
        ///   - bindingKind: The binding's persisted agent kind.
        ///   - bindingSessionID: The binding's checkpoint identity.
        ///   - bindingSource: The binding publisher source.
        ///   - autoResume: Whether automatic resume was enabled.
        public init(
            agentKind: String,
            agentSessionID: String,
            hadActivePromptTurn: Bool?,
            wasAgentRunning: Bool? = nil,
            bindingKind: String?,
            bindingSessionID: String?,
            bindingSource: String?,
            autoResume: Bool?
        ) {
            self.agentKind = agentKind
            self.agentSessionID = agentSessionID
            self.hadActivePromptTurn = hadActivePromptTurn
            self.wasAgentRunning = wasAgentRunning
            self.bindingKind = bindingKind
            self.bindingSessionID = bindingSessionID
            self.bindingSource = bindingSource
            self.autoResume = autoResume
        }
    }

    /// Creates the stateless admission policy.
    public init() {}

    /// Returns whether the binding proves a safe, normally completed Claude
    /// session that can use native `claude --resume`.
    ///
    /// Binding source, automatic-resume consent, kind, and the checkpoint
    /// identity are all required. Session IDs are trimmed but remain
    /// case-sensitive, matching Claude's existing identity comparison.
    ///
    /// - Parameter evidence: Captured snapshot and binding evidence.
    /// - Returns: Whether automatic resume may enter the existing restore admission path.
    public func admits(_ evidence: AdmissionEvidence) -> Bool {
        guard isNormallyEndedClaude(
                  agentKind: evidence.agentKind,
                  hadActivePromptTurn: evidence.hadActivePromptTurn,
                  wasAgentRunning: evidence.wasAgentRunning
              ),
              normalized(evidence.bindingKind) == Self.claudeKind,
              evidence.bindingSource == Self.agentHookSource,
              evidence.autoResume == true,
              let agentSessionID = normalized(evidence.agentSessionID),
              let bindingSessionID = normalized(evidence.bindingSessionID) else {
            return false
        }
        return agentSessionID == bindingSessionID
    }

    private func isNormallyEndedClaude(
        agentKind: String,
        hadActivePromptTurn: Bool?,
        wasAgentRunning: Bool?
    ) -> Bool {
        guard normalized(agentKind) == Self.claudeKind else { return false }
        return hadActivePromptTurn == false ||
            (hadActivePromptTurn == nil && wasAgentRunning == false)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
