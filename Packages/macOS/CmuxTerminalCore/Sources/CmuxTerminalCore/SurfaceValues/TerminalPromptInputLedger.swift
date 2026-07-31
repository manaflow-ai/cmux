/// Conservative input ownership and bounded hook matching used to keep
/// app-owned submissions separate from human terminal-composer drafts.
public struct TerminalPromptInputLedger: Sendable {
    private static let maximumPendingBoundaries = 64

    private var agentScope: String?
    private var humanInputGeneration: UInt64 = 0
    private var confirmedHumanInputGeneration: UInt64 = 0
    private var pendingBoundaries: [TerminalPromptSubmissionBoundary] = []
    private var humanBoundaryOrderingWasLost = false

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
        humanBoundaryOrderingWasLost = false
    }

    /// True when human input occurred after the last safely matched human
    /// submission boundary.
    public var hasUnconfirmedHumanInput: Bool {
        humanInputGeneration != confirmedHumanInputGeneration
    }

    /// Records one human terminal input event.
    ///
    /// A submit-capable Return records a boundary but does not clear ownership
    /// until an agent hook confirms it. Return can also activate menus or
    /// confirmations while leaving a draft intact, so clearing immediately
    /// would permit a later app-owned prompt to clobber that draft.
    ///
    /// - Parameter maySubmitPrompt: Whether this event may create the next
    ///   agent prompt-submission hook.
    public mutating func recordHumanInput(maySubmitPrompt: Bool) {
        humanInputGeneration &+= 1
        if humanInputGeneration == 0 {
            // A wrap cannot preserve generation ordering. Fail closed until
            // the active agent scope changes.
            humanInputGeneration = 1
            confirmedHumanInputGeneration = 0
            humanBoundaryOrderingWasLost = true
            removeHumanBoundaries()
        }
        guard maySubmitPrompt, !humanBoundaryOrderingWasLost else { return }
        appendHumanBoundary(generation: humanInputGeneration)
    }

    /// Records an accepted app-owned prompt for later message-matched hook
    /// confirmation.
    ///
    /// The queue is bounded. When full, only another app-owned record may be
    /// evicted; human boundaries are never discarded because doing so could
    /// let an unrelated hook clear a newer draft.
    public mutating func recordProgrammaticSubmission(
        message: String,
        source: String?
    ) {
        guard let source,
              let messageSignature = messageSignature(message) else {
            return
        }
        if pendingBoundaries.count == Self.maximumPendingBoundaries {
            guard let index = pendingBoundaries.firstIndex(where: {
                if case .programmatic = $0 { return true }
                return false
            }) else {
                return
            }
            pendingBoundaries.remove(at: index)
        }
        pendingBoundaries.append(.programmatic(
            messageSignature: messageSignature,
            source: source
        ))
    }

    /// Matches an agent `UserPromptSubmit` hook to a known prompt boundary.
    ///
    /// App-owned records match by message rather than position. An unmatched
    /// hook may confirm the oldest human boundary only when no earlier
    /// app-owned record could own it, preserving newer human input.
    @discardableResult
    public mutating func confirmSubmission(message: String?)
        -> PromptSubmissionConfirmationOrigin
    {
        if let message,
           let messageSignature = messageSignature(message),
           let index = pendingBoundaries.firstIndex(where: {
               guard case .programmatic(
                   let candidateSignature,
                   _
               ) = $0 else {
                   return false
               }
               return candidateSignature == messageSignature
           }) {
            guard case .programmatic(
                _,
                let source
            ) = pendingBoundaries.remove(at: index) else {
                return .unmatched
            }
            return .programmatic(source: source)
        }
        guard !humanBoundaryOrderingWasLost,
              let first = pendingBoundaries.first,
              case .human(let generation) = first else {
            return .unmatched
        }
        pendingBoundaries.removeFirst()
        confirmedHumanInputGeneration = generation
        return .human
    }

    private mutating func appendHumanBoundary(generation: UInt64) {
        guard pendingBoundaries.count < Self.maximumPendingBoundaries else {
            humanBoundaryOrderingWasLost = true
            removeHumanBoundaries()
            return
        }
        pendingBoundaries.append(.human(generation: generation))
    }

    private mutating func removeHumanBoundaries() {
        pendingBoundaries.removeAll {
            if case .human = $0 { return true }
            return false
        }
    }

    private func messageSignature(
        _ message: String
    ) -> TerminalPromptMessageSignature? {
        let normalized = message
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        var primaryHash: UInt64 = 14_695_981_039_346_656_037
        var secondaryHash: UInt64 = 7_809_847_782_469_553_657
        var byteCount = 0
        for byte in normalized.utf8 {
            primaryHash ^= UInt64(byte)
            primaryHash &*= 1_099_511_628_211
            secondaryHash &*= 1_099_511_628_211
            secondaryHash ^= UInt64(byte)
            byteCount += 1
        }
        return TerminalPromptMessageSignature(
            primaryHash: primaryHash,
            secondaryHash: secondaryHash,
            byteCount: byteCount
        )
    }
}
