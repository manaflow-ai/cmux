import Foundation

/// Decides when a completed Claude session may bypass the restore admission path.
///
/// Claude hook snapshots carry an explicit prompt-turn marker. Only an explicit
/// `false` proves that no deferred tool continuation is waiting; a missing value
/// is legacy data and remains on the conservative restore path.
public struct NormallyEndedClaudeResumePolicy: Sendable {
    /// The normalized kind used by Claude Code hook bindings.
    public static let claudeKind = "claude"

    /// The hook source required for automatic resume admission.
    public static let agentHookSource = "agent-hook"

    /// The evidence needed to admit a normally completed Claude session.
    public struct AdmissionEvidence: Sendable {
        public var agentKind: String
        public var agentSessionID: String
        public var hadActivePromptTurn: Bool?
        public var bindingKind: String?
        public var bindingSessionID: String?
        public var bindingSource: String?
        public var autoResume: Bool?

        public init(
            agentKind: String,
            agentSessionID: String,
            hadActivePromptTurn: Bool?,
            bindingKind: String?,
            bindingSessionID: String?,
            bindingSource: String?,
            autoResume: Bool?
        ) {
            self.agentKind = agentKind
            self.agentSessionID = agentSessionID
            self.hadActivePromptTurn = hadActivePromptTurn
            self.bindingKind = bindingKind
            self.bindingSessionID = bindingSessionID
            self.bindingSource = bindingSource
            self.autoResume = autoResume
        }
    }

    /// Creates the stateless admission policy.
    public init() {}

    /// Keeps the local `cmux restore` verb for deferred or unknown Claude work.
    ///
    /// A normally ended Claude session is launched through its native resume
    /// command, while every other agent and every unknown marker retains the
    /// caller's existing restore-verb choice.
    public func usesLocalRestoreVerb(
        requested: Bool,
        agentKind: String,
        hadActivePromptTurn: Bool?
    ) -> Bool {
        requested && !isNormallyEndedClaude(
            agentKind: agentKind,
            hadActivePromptTurn: hadActivePromptTurn
        )
    }

    /// Returns whether the binding proves a safe, normally completed Claude
    /// session that can use native `claude --resume`.
    ///
    /// Binding source, automatic-resume consent, kind, and the checkpoint
    /// identity are all required. Session IDs are trimmed but remain
    /// case-sensitive, matching Claude's existing identity comparison.
    public func admits(_ evidence: AdmissionEvidence) -> Bool {
        guard isNormallyEndedClaude(
                  agentKind: evidence.agentKind,
                  hadActivePromptTurn: evidence.hadActivePromptTurn
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
        hadActivePromptTurn: Bool?
    ) -> Bool {
        normalized(agentKind) == Self.claudeKind && hadActivePromptTurn == false
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
