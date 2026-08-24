internal import CryptoKit
internal import Foundation

/// Conservative input ownership and bounded hook matching used to keep
/// app-owned submissions separate from human terminal-composer drafts.
public struct TerminalPromptInputLedger: Sendable {
    private static let maximumPendingBoundaries = 64

    private var agentScope: String?
    private var lastBoundAgentScope: String?
    private var humanInputEpoch: UInt64 = 0
    private var humanInputGeneration: UInt64 = 0
    private var confirmedHumanInputGeneration: UInt64 = 0
    private var pendingBoundaries: [TerminalPromptSubmissionBoundary] = []

    /// Creates an empty ledger with no human input or pending boundaries.
    public init() {}

    /// Aligns provisional input ownership with the active agent process.
    ///
    /// Human input can reach the terminal before the process identity becomes
    /// available. On the initial binding, a completed human submission boundary
    /// retires the input through that boundary while trailing input remains
    /// fail-closed; unowned app submissions are discarded. Temporary scope
    /// unavailability preserves the last process's evidence but reports no
    /// current scope, so guarded automation remains unavailable. Binding a
    /// different process starts a fresh epoch so one agent cannot inherit
    /// another agent's composer state.
    public mutating func synchronizeAgentScope(_ scope: String?) {
        guard agentScope != scope else { return }

        agentScope = scope
        guard let scope else {
            return
        }

        let previousBoundScope = lastBoundAgentScope
        lastBoundAgentScope = scope
        guard previousBoundScope != scope else {
            return
        }

        if previousBoundScope == nil {
            humanInputEpoch &+= 1
            removeNonHumanBoundaries()
            confirmProvisionalInputThroughLastBoundary()
            return
        }

        humanInputEpoch &+= 1
        humanInputGeneration = 0
        confirmedHumanInputGeneration = 0
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

    /// Records one human terminal input event.
    ///
    /// A submission boundary records only a possible recovery boundary; it
    /// never makes the composer available on its own. The ledger stays busy
    /// until an actual agent `UserPromptSubmit` hook confirms that boundary.
    /// This means agent-specific key handling can conservatively produce a
    /// false negative without weakening draft safety: one hook confirms at
    /// most one possible boundary, and an agent-process transition remains the
    /// definitive recovery. Unknown cancellation or delete-to-empty input
    /// deliberately stays busy until that proof or transition; state alone
    /// cannot prove the TUI is empty.
    public mutating func recordHumanInput(
        _ mutation: HumanPromptInputMutation
    ) {
        humanInputGeneration &+= 1
        if humanInputGeneration == 0 {
            // A wrap cannot preserve generation ordering. Keep the current
            // composer fail-closed, but allow a later boundary and hook to
            // establish a new recoverable epoch.
            humanInputEpoch &+= 1
            humanInputGeneration = 1
            confirmedHumanInputGeneration = 0
            removeHumanBoundaries()
        }
        switch mutation {
        case .submissionBoundary:
            appendHumanBoundary(generation: humanInputGeneration)
        case .unknown:
            break
        }
    }

    /// Captures the physical-input ownership epoch and generation at an app
    /// action's admission boundary.
    public var humanInputSnapshot: HumanInputSnapshot {
        HumanInputSnapshot(
            epoch: humanInputEpoch,
            generation: humanInputGeneration
        )
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
        confirmsHumanInputSnapshot: HumanInputSnapshot? = nil
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
            confirmsHumanInputSnapshot: confirmsHumanInputSnapshot
        ))
    }

    /// Matches an agent `UserPromptSubmit` hook to a known prompt boundary.
    ///
    /// App-owned records match by message rather than position. An unmatched
    /// hook may confirm one leading human boundary only when no pending
    /// app-owned record could own it. Confirming at most one possible boundary
    /// per hook prevents a later non-submitting Return from being mistaken for
    /// proof that newer human input is gone.
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
                    let confirmsHumanInputSnapshot
                ) = pendingBoundaries.remove(at: index) else {
                    return .unmatched
                }
                if let confirmsHumanInputSnapshot,
                   confirmsHumanInputSnapshot.epoch == humanInputEpoch {
                    confirmedHumanInputGeneration = max(
                        confirmedHumanInputGeneration,
                        confirmsHumanInputSnapshot.generation
                    )
                }
                return .programmatic(source: source)
            }
        }
        // Agent versions can normalize or rewrite the prompt before emitting
        // their hook. Preserve hook ordering without wedging human ownership:
        // an unmatched hook consumes one older programmatic boundary, but never
        // a human boundary in the same call.
        if consumeEarliestProgrammaticBoundary() {
            return .unmatched
        }
        guard let first = pendingBoundaries.first,
              case .human(let generation) = first else {
            return .unmatched
        }
        pendingBoundaries.removeFirst()
        confirmedHumanInputGeneration = max(
            confirmedHumanInputGeneration,
            generation
        )
        return .human
    }

    /// Retires one possible app-owned hook before unmatched attribution may
    /// consume a human boundary, even when that app record sits behind it.
    private mutating func consumeEarliestProgrammaticBoundary() -> Bool {
        guard let index = pendingBoundaries.firstIndex(where: {
            switch $0 {
            case .programmatic, .retiredProgrammatic:
                return true
            case .human:
                return false
            }
        }) else {
            return false
        }
        guard case .retiredProgrammatic(let count) =
                pendingBoundaries[index] else {
            pendingBoundaries.remove(at: index)
            return true
        }
        if count == 1 {
            pendingBoundaries.remove(at: index)
        } else {
            pendingBoundaries[index] = .retiredProgrammatic(
                count: count - 1
            )
        }
        return true
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
        // fail-closed until a later confirmed boundary or process transition.
        guard humanBoundaryCount < Self.maximumPendingBoundaries else { return }
        pendingBoundaries.append(.human(generation: generation))
    }

    private mutating func removeHumanBoundaries() {
        pendingBoundaries.removeAll {
            if case .human = $0 { return true }
            return false
        }
    }

    private mutating func removeNonHumanBoundaries() {
        pendingBoundaries.removeAll {
            if case .human = $0 { return false }
            return true
        }
    }

    /// A complete pre-bind submission cannot remain an in-progress composer
    /// draft. Retire input only through the latest retained boundary; input
    /// recorded after it remains busy, including bytes typed during startup.
    private mutating func confirmProvisionalInputThroughLastBoundary() {
        guard let boundary = pendingBoundaries.last(where: {
            if case .human = $0 { return true }
            return false
        }),
              case .human(let generation) = boundary else {
            return
        }
        confirmedHumanInputGeneration = max(
            confirmedHumanInputGeneration,
            generation
        )
        pendingBoundaries.removeAll {
            guard case .human(let boundaryGeneration) = $0 else {
                return false
            }
            return boundaryGeneration <= generation
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
        let bytes = Data(normalized.utf8)
        return TerminalPromptMessageSignature(
            digest: Array(SHA256.hash(data: bytes)),
            byteCount: bytes.count
        )
    }
}
