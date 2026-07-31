/// Conservative input ownership used to keep programmatic prompt submissions
/// from merging with a human's in-progress terminal-composer draft.
///
/// Normal typing only increments a counter. Submission-boundary bookkeeping is
/// intentionally separate so a delayed agent hook can confirm the exact human
/// input generation that preceded it without clearing newer typing.
public struct TerminalPromptInputLedger: Sendable {
    private static let maximumPendingBoundaries = 64

    private var agentScope: String?
    private var humanInputGeneration: UInt64 = 0
    private var confirmedHumanInputGeneration: UInt64 = 0
    private var pendingBoundaries: [TerminalPromptSubmissionBoundary] = []
    private var boundaryOrderingWasLost = false

    /// Creates an empty ledger with no human input or pending boundaries.
    public init() {}

    /// Starts a fresh ownership epoch when the active agent changes.
    ///
    /// Physical input from a shell or a previous agent cannot describe the
    /// current agent's composer. Clearing it at the binding transition avoids
    /// both false busy rejections and stale hook boundaries.
    public mutating func synchronizeAgentScope(_ scope: String?) {
        guard agentScope != scope else { return }
        agentScope = scope
        humanInputGeneration = 0
        confirmedHumanInputGeneration = 0
        pendingBoundaries.removeAll(keepingCapacity: false)
        boundaryOrderingWasLost = false
    }

    /// True when human input occurred after the last safely matched human
    /// submission boundary.
    public var hasUnconfirmedHumanInput: Bool {
        humanInputGeneration != confirmedHumanInputGeneration
    }

    /// Records one physical terminal input event. The common typing path only
    /// mutates integers; the small boundary queue grows only for submit keys.
    ///
    /// - Parameter maySubmitPrompt: Whether this event may create the next
    ///   agent prompt-submission hook.
    public mutating func recordHumanInput(maySubmitPrompt: Bool) {
        humanInputGeneration &+= 1
        if humanInputGeneration == 0 {
            // A wrap cannot preserve generation ordering. Fail closed.
            humanInputGeneration = 1
            confirmedHumanInputGeneration = 0
            pendingBoundaries.removeAll(keepingCapacity: false)
            boundaryOrderingWasLost = true
        }
        guard maySubmitPrompt else { return }
        appendBoundary(.human(generation: humanInputGeneration))
    }

    /// Records an accepted app-owned prompt transaction. Its eventual hook
    /// must not clear human input that arrived after this transaction.
    ///
    /// - Parameter hookRecording: The hook's remaining recording ownership, or
    ///   `nil` when this target is not expected to emit an agent hook.
    public mutating func recordProgrammaticSubmission(
        hookRecording: ProgrammaticPromptHookRecording?
    ) {
        guard let hookRecording else { return }
        appendBoundary(.programmatic(hookRecording))
    }

    /// Matches the next agent `UserPromptSubmit` hook to its input boundary.
    ///
    /// If ordering was lost or the hook has no known boundary, human input is
    /// deliberately left busy.
    ///
    /// - Returns: The boundary origin, including any remaining hook work.
    @discardableResult
    public mutating func confirmNextSubmission()
        -> PromptSubmissionConfirmationOrigin
    {
        guard !boundaryOrderingWasLost, !pendingBoundaries.isEmpty else {
            return .unmatched
        }
        switch pendingBoundaries.removeFirst() {
        case .human(let generation):
            confirmedHumanInputGeneration = generation
            return .human
        case .programmatic(let hookRecording):
            return .programmatic(hookRecording)
        }
    }

    private mutating func appendBoundary(
        _ boundary: TerminalPromptSubmissionBoundary
    ) {
        guard !boundaryOrderingWasLost else { return }
        guard pendingBoundaries.count < Self.maximumPendingBoundaries else {
            pendingBoundaries.removeAll(keepingCapacity: false)
            boundaryOrderingWasLost = true
            return
        }
        pendingBoundaries.append(boundary)
    }
}
