/// The lifecycle facts needed to decide whether a completion Stop preserves a
/// user attention request.
///
/// The decision belongs in the journal domain so every agent integration uses
/// the same turn and termination invariants before projecting state to a
/// sidebar or notification.
public struct AgentNeedsInputStopContext: Equatable, Sendable {
    /// The phase recorded before the completion Stop arrived.
    public let runtimePhase: AgentLifecyclePhase?
    /// The number of prompt turns still owned by the session.
    public let activePromptDepth: Int
    /// The active prompt turn identifiers, newest last.
    public let activePromptTurnIDs: [String]
    /// The single active prompt identifier used by older integrations.
    public let activePromptTurnID: String?
    /// The most recently submitted prompt turn identifier.
    public let lastPromptTurnID: String?
    /// The turn identifier carried by the completion Stop.
    public let inputTurnID: String?
    /// The native reason carried by the completion Stop.
    public let terminationReason: String?

    /// Creates a stop-decision context from one agent session snapshot.
    ///
    /// - Parameters:
    ///   - runtimePhase: The phase persisted before the Stop.
    ///   - activePromptDepth: The session's active prompt depth.
    ///   - activePromptTurnIDs: Known active prompt turn identifiers.
    ///   - activePromptTurnID: The legacy single active prompt identifier.
    ///   - lastPromptTurnID: The most recently submitted prompt identifier.
    ///   - inputTurnID: The identifier carried by the Stop.
    ///   - terminationReason: The native Stop reason.
    public init(
        runtimePhase: AgentLifecyclePhase?,
        activePromptDepth: Int = 0,
        activePromptTurnIDs: [String] = [],
        activePromptTurnID: String? = nil,
        lastPromptTurnID: String? = nil,
        inputTurnID: String? = nil,
        terminationReason: String? = nil
    ) {
        self.runtimePhase = runtimePhase
        self.activePromptDepth = max(activePromptDepth, 0)
        self.activePromptTurnIDs = activePromptTurnIDs
        self.activePromptTurnID = activePromptTurnID
        self.lastPromptTurnID = lastPromptTurnID
        self.inputTurnID = inputTurnID
        self.terminationReason = terminationReason
    }

    /// Whether this Stop is the same turn's attention-preserving completion.
    public var shouldPreserveNeedsInput: Bool {
        guard runtimePhase == .needsInput else { return false }
        guard !isSessionTermination else { return false }

        let normalizedInputTurnID = normalizedTurnID(inputTurnID)
        let normalizedActiveTurnIDs = activePromptTurnIDs.compactMap { normalizedTurnID($0) }
        let normalizedActiveTurnID = normalizedTurnID(activePromptTurnID)
        let normalizedLastTurnID = normalizedTurnID(lastPromptTurnID)
        if let normalizedInputTurnID {
            let activeTurnIDs = normalizedActiveTurnIDs.isEmpty
                ? normalizedActiveTurnID.map { [$0] } ?? []
                : normalizedActiveTurnIDs
            return activeTurnIDs.contains(normalizedInputTurnID)
                || normalizedLastTurnID == normalizedInputTurnID
        }
        return activePromptDepth > 0
            || normalizedActiveTurnID != nil
            || !normalizedActiveTurnIDs.isEmpty
    }

    private var isSessionTermination: Bool {
        guard let terminationReason = normalizedReason(terminationReason) else { return false }
        return [
            "cancel", "abort", "interrupt", "shutdown", "terminate",
            "session_end", "session-end", "exit",
        ].contains { terminationReason.contains($0) }
    }

    private func normalizedTurnID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedReason(_ value: String?) -> String? {
        normalizedTurnID(value)?.lowercased()
    }
}
