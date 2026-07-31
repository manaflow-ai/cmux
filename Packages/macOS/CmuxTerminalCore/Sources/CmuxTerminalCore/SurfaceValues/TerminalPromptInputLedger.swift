/// Conservative input ownership and bounded hook matching used to keep
/// app-owned submissions separate from human terminal-composer drafts.
public struct TerminalPromptInputLedger: Sendable {
    private static let maximumPendingBoundaries = 64

    private var agentScope: String?
    private var humanInputGeneration: UInt64 = 0
    private var confirmedHumanInputGeneration: UInt64 = 0
    private var pendingBoundaries: [TerminalPromptSubmissionBoundary] = []

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
    }

    /// True when human input occurred after the last safely matched human
    /// submission boundary.
    public var hasUnconfirmedHumanInput: Bool {
        humanInputGeneration != confirmedHumanInputGeneration
    }

    /// Records one human terminal input event.
    ///
    /// A submit-capable Return records only a possible recovery boundary; it
    /// never makes the composer available on its own. The ledger stays busy
    /// until an actual agent `UserPromptSubmit` hook confirms that boundary.
    /// This means agent-specific key handling can conservatively produce a
    /// false negative without weakening draft safety: a later known boundary
    /// and hook can still recover the ledger.
    ///
    /// - Parameter maySubmitPrompt: Whether this event may create the next
    ///   agent prompt-submission hook.
    public mutating func recordHumanInput(maySubmitPrompt: Bool) {
        humanInputGeneration &+= 1
        if humanInputGeneration == 0 {
            // A wrap cannot preserve generation ordering. Keep the current
            // composer fail-closed, but allow a later boundary and hook to
            // establish a new recoverable epoch.
            humanInputGeneration = 1
            confirmedHumanInputGeneration = 0
            removeHumanBoundaries()
        }
        guard maySubmitPrompt else { return }
        appendHumanBoundary(generation: humanInputGeneration)
    }

    /// Whether another app-owned hook attribution can be retained.
    ///
    /// Delivery checks this before writing any bytes. Cold-surface compound
    /// items count as reservations at the surface layer and become ledger
    /// records only after they are actually flushed.
    public func canRecordProgrammaticSubmission(
        additionalCount: Int = 1
    ) -> Bool {
        guard additionalCount >= 0,
              additionalCount <= Self.maximumPendingBoundaries else {
            return false
        }
        let count = pendingBoundaries.reduce(into: 0) { count, boundary in
            if case .programmatic = boundary {
                count += 1
            }
        }
        return count <= Self.maximumPendingBoundaries - additionalCount
    }

    /// Records an accepted app-owned prompt for later message-matched hook
    /// confirmation.
    ///
    /// - Returns: `false` when the bounded attribution queue is full. Callers
    ///   must treat that as rejection before terminal delivery.
    @discardableResult
    public mutating func recordProgrammaticSubmission(
        message: String,
        source: String?,
        confirmsHumanInput: Bool = false
    ) -> Bool {
        guard let source,
              let messageSignature = messageSignature(message) else {
            return true
        }
        guard canRecordProgrammaticSubmission() else { return false }
        pendingBoundaries.append(.programmatic(
            messageSignature: messageSignature,
            source: source,
            confirmsHumanInputGeneration:
                confirmsHumanInput ? humanInputGeneration : nil
        ))
        return true
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
                   _,
                   _
               ) = $0 else {
                   return false
               }
               return candidateSignature == messageSignature
           }) {
            guard case .programmatic(
                _,
                let source,
                let confirmsHumanInputGeneration
            ) = pendingBoundaries.remove(at: index) else {
                return .unmatched
            }
            if let confirmsHumanInputGeneration {
                confirmedHumanInputGeneration =
                    confirmsHumanInputGeneration
            }
            return .programmatic(source: source)
        }
        guard let first = pendingBoundaries.first,
              case .human(let generation) = first else {
            return .unmatched
        }
        pendingBoundaries.removeFirst()
        confirmedHumanInputGeneration = generation
        return .human
    }

    private mutating func appendHumanBoundary(generation: UInt64) {
        let humanBoundaryCount = pendingBoundaries.reduce(
            into: 0
        ) { count, boundary in
            if case .human = boundary {
                count += 1
            }
        }
        // Never discard or coalesce an older boundary: doing so could let its
        // delayed hook clear newer typing. Skipping this boundary remains
        // fail-closed, and once older hooks drain, any later Return plus hook
        // can recover normally.
        guard humanBoundaryCount < Self.maximumPendingBoundaries else { return }
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
