/// Conservative input ownership and bounded hook matching used to keep
/// app-owned submissions separate from human terminal-composer drafts.
public struct TerminalPromptInputLedger: Sendable {
    private static let maximumPendingBoundaries = 64

    private var agentScope: String?
    private var humanInputGeneration: UInt64 = 0
    private var confirmedHumanInputGeneration: UInt64 = 0
    private var knownHumanComposerLength: Int? = 0
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
        knownHumanComposerLength = 0
        pendingBoundaries.removeAll(keepingCapacity: false)
    }

    /// True when human input occurred after the last safely matched human
    /// submission boundary.
    public var hasUnconfirmedHumanInput: Bool {
        humanInputGeneration != confirmedHumanInputGeneration
    }

    /// The single agent-process identity that owns the current composer epoch.
    public var currentAgentScope: String? {
        agentScope
    }

    /// Whether physical terminal input belongs to an active agent composer.
    public var hasAgentScope: Bool {
        agentScope != nil
    }

    /// Records one human terminal input event.
    ///
    /// A submission boundary records only a possible recovery boundary; it
    /// never makes the composer available on its own. The ledger stays busy
    /// until an actual agent `UserPromptSubmit` hook confirms that boundary.
    /// This means agent-specific key handling can conservatively produce a
    /// false negative without weakening draft safety: a later known boundary
    /// and hook can still recover the ledger.
    ///
    /// Simple insert/backspace sequences retain exact length knowledge, so
    /// deleting a freshly typed draft back to zero recovers without guessing
    /// or waiting for a hook. Any editor-dependent operation loses that
    /// knowledge and stays fail-closed.
    public mutating func recordHumanInput(
        _ mutation: HumanPromptInputMutation
    ) {
        humanInputGeneration &+= 1
        if humanInputGeneration == 0 {
            // A wrap cannot preserve generation ordering. Keep the current
            // composer fail-closed, but allow a later boundary and hook to
            // establish a new recoverable epoch.
            humanInputGeneration = 1
            confirmedHumanInputGeneration = 0
            knownHumanComposerLength = nil
            removeHumanBoundaries()
        }
        switch mutation {
        case .insert(let characterCount):
            guard characterCount > 0 else { return }
            if let knownHumanComposerLength {
                let (updatedLength, overflowed) =
                    knownHumanComposerLength.addingReportingOverflow(
                        characterCount
                    )
                self.knownHumanComposerLength =
                    overflowed ? nil : updatedLength
            }
        case .backspace:
            guard let knownHumanComposerLength else { return }
            let remaining = max(knownHumanComposerLength - 1, 0)
            self.knownHumanComposerLength = remaining
            if remaining == 0 {
                confirmedHumanInputGeneration = humanInputGeneration
                removeHumanBoundaries()
            }
        case .submissionBoundary:
            knownHumanComposerLength = nil
            appendHumanBoundary(generation: humanInputGeneration)
        case .unknown:
            knownHumanComposerLength = nil
        }
    }

    /// Captures the physical-input ownership generation at an app action's
    /// admission boundary.
    public var humanInputGenerationSnapshot: UInt64 {
        humanInputGeneration
    }

    /// Records an accepted app-owned prompt for later message-matched hook
    /// confirmation.
    ///
    /// Exact source attribution is bounded. Once full, the oldest record
    /// degrades in place to a sequence-only programmatic boundary. Adjacent
    /// retired boundaries coalesce, so delayed or rewritten hooks cannot
    /// consume a human boundary and new prompt delivery remains live.
    public mutating func recordProgrammaticSubmission(
        message: String,
        source: String?,
        confirmsHumanInputGeneration: UInt64? = nil
    ) {
        guard let source,
              let messageSignature = messageSignature(message) else {
            return
        }
        let exactProgrammaticCount = pendingBoundaries.reduce(
            into: 0
        ) { count, boundary in
            if case .programmatic = boundary {
                count += 1
            }
        }
        if exactProgrammaticCount == Self.maximumPendingBoundaries,
           let oldestIndex = pendingBoundaries.firstIndex(where: {
               if case .programmatic = $0 {
                   return true
               }
               return false
           }) {
            retireProgrammaticBoundary(at: oldestIndex)
        }
        pendingBoundaries.append(.programmatic(
            messageSignature: messageSignature,
            source: source,
            confirmsHumanInputGeneration: confirmsHumanInputGeneration
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
           let messageSignature = messageSignature(message) {
            if let index = pendingBoundaries.firstIndex(where: {
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
                    confirmedHumanInputGeneration = max(
                        confirmedHumanInputGeneration,
                        confirmsHumanInputGeneration
                    )
                    knownHumanComposerLength =
                        humanInputGeneration == confirmedHumanInputGeneration
                            ? 0
                            : nil
                }
                return .programmatic(source: source)
            }
        }
        // Agent versions can normalize or rewrite the prompt before emitting
        // their hook. Preserve hook ordering without wedging human ownership:
        // an unmatched hook consumes one older programmatic boundary, but never
        // a human boundary in the same call.
        if let first = pendingBoundaries.first,
           case .programmatic(
               _,
               _,
               _
           ) = first {
            pendingBoundaries.removeFirst()
            return .unmatched
        }
        if let first = pendingBoundaries.first,
           case .retiredProgrammatic(let count) = first {
            if count == 1 {
                pendingBoundaries.removeFirst()
            } else {
                pendingBoundaries[0] = .retiredProgrammatic(count: count - 1)
            }
            return .unmatched
        }
        guard let first = pendingBoundaries.first,
              case .human(let generation) = first else {
            return .unmatched
        }
        pendingBoundaries.removeFirst()
        confirmedHumanInputGeneration = generation
        knownHumanComposerLength =
            humanInputGeneration == generation ? 0 : nil
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

    private mutating func retireProgrammaticBoundary(at index: Int) {
        pendingBoundaries[index] = .retiredProgrammatic(count: 1)
        var retiredIndex = index

        if index > pendingBoundaries.startIndex,
           case .retiredProgrammatic(let previousCount) =
               pendingBoundaries[index - 1],
           case .retiredProgrammatic(let currentCount) =
               pendingBoundaries[index] {
            pendingBoundaries[index - 1] = .retiredProgrammatic(
                count: addingWithoutOverflow(previousCount, currentCount)
            )
            pendingBoundaries.remove(at: index)
            retiredIndex = index - 1
        }

        guard pendingBoundaries.indices.contains(retiredIndex + 1),
              case .retiredProgrammatic(let currentCount) =
                  pendingBoundaries[retiredIndex],
              case .retiredProgrammatic(let nextCount) =
                  pendingBoundaries[retiredIndex + 1] else {
            return
        }
        pendingBoundaries[retiredIndex] = .retiredProgrammatic(
            count: addingWithoutOverflow(currentCount, nextCount)
        )
        pendingBoundaries.remove(at: retiredIndex + 1)
    }

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
        return overflowed ? UInt64.max : sum
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
