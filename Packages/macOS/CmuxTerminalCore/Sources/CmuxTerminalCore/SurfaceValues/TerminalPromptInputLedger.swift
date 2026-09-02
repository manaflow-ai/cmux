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
    private var hasEvictedProgrammaticTombstones = false

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
    ///
    /// - Parameter provisionalSubmissionBoundariesAreReliable: Whether a
    ///   boundary recorded before the first process binding can represent a
    ///   completed prompt. Claude's plain Return is an interior newline, so
    ///   its first binding passes `false` and keeps that input fail-closed.
    public mutating func synchronizeAgentScope(
        _ scope: String?,
        provisionalSubmissionBoundariesAreReliable: Bool = true
    ) {
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
            if provisionalSubmissionBoundariesAreReliable {
                confirmProvisionalInputThroughLastBoundary()
            }
            return
        }

        humanInputEpoch &+= 1
        humanInputGeneration = 0
        confirmedHumanInputGeneration = 0
        pendingBoundaries.removeAll(keepingCapacity: false)
        hasEvictedProgrammaticTombstones = false
    }

    /// True when human input occurred after the last safely matched human
    /// submission boundary.
    public var hasUnconfirmedHumanInput: Bool {
        humanInputGeneration != confirmedHumanInputGeneration
    }

    /// Whether an app-owned prompt still awaits authoritative hook matching.
    public var hasPendingProgrammaticSubmission: Bool {
        pendingBoundaries.contains { boundary in
            switch boundary {
            case .programmatic, .confirmedProgrammatic, .retiredProgrammatic:
                return true
            case .human:
                return false
            }
        }
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
        if exactProgrammaticCount >= Self.maximumPendingBoundaries,
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
        removeProgrammaticBoundariesSupersededByHumanInput()
        if let message,
           let messageSignature = messageSignature(message) {
            if let index = pendingBoundaries.firstIndex(where: {
                guard case .programmatic(let candidateSignature, _, _) = $0
                else { return false }
                return candidateSignature == messageSignature
            }) {
                guard case .programmatic(
                    let candidateSignature,
                    let source,
                    let confirmsHumanInputSnapshot
                ) = pendingBoundaries[index] else {
                    return .unmatched
                }
                // Keep a duplicate-hook tombstone even when no human boundary
                // is currently pending. New human boundaries are inserted
                // ahead of tombstones, while exact duplicate hooks still find
                // and consume this record.
                pendingBoundaries.remove(at: index)
                pendingBoundaries.append(.confirmedProgrammatic(
                    messageSignature: candidateSignature
                ))
                trimConfirmedProgrammaticBoundaries()
                if let confirmsHumanInputSnapshot,
                   confirmsHumanInputSnapshot.epoch == humanInputEpoch {
                    confirmHumanInputThroughGeneration(
                        confirmsHumanInputSnapshot.generation
                    )
                }
                return .programmatic(source: source)
            }
            if let index = pendingBoundaries.firstIndex(where: {
                guard case .confirmedProgrammatic(let candidateSignature) = $0
                else { return false }
                return candidateSignature == messageSignature
            }) {
                let hasEarlierHumanBoundary = pendingBoundaries[..<index]
                    .contains {
                        if case .human = $0 { return true }
                        return false
                    }
                if !hasEarlierHumanBoundary {
                    // A duplicate exact hook is already accounted for.
                    // Consume only its tombstone; never reinterpret it as
                    // human input when no earlier human boundary is waiting.
                    pendingBoundaries.remove(at: index)
                    return .programmaticDuplicate
                }
                // A duplicate app hook and a human hook carrying the same
                // normalized text are observationally indistinguishable. Keep
                // the replay tombstone authoritative and fail closed rather
                // than clearing the human boundary on an app replay.
                return .unmatched
            }
        }
        if hasEvictedProgrammaticTombstones,
           pendingBoundaries.contains(where: { boundary in
               if case .human = boundary { return true }
               return false
           }) {
            // A delayed duplicate for an evicted app tombstone must never
            // consume a human boundary merely because its message is unknown.
            return .unmatched
        }
        // Agent versions can normalize or rewrite the prompt before emitting
        // their hook. Preserve hook ordering without wedging human ownership:
        // an unmatched hook consumes one older programmatic boundary, but never
        // a human boundary in the same call.
        if consumeEarliestProgrammaticBoundary() {
            return .programmaticUnmatched
        }
        guard let first = pendingBoundaries.first,
              case .human(let generation) = first else {
            return .unmatched
        }
        pendingBoundaries.removeFirst()
        confirmHumanInputThroughGeneration(generation)
        return .human
    }

    /// Removes app-owned records whose admission snapshot predates newer
    /// human input in the same epoch. An identical human prompt must not be
    /// attributed to the older app transaction merely because its text
    /// signature matches.
    private mutating func removeProgrammaticBoundariesSupersededByHumanInput() {
        let currentBoundaries = pendingBoundaries
        pendingBoundaries = currentBoundaries.filter { boundary in
            guard case .programmatic(
                _, _, let snapshot
            ) = boundary else {
                return true
            }
            guard let snapshot else { return true }
            guard snapshot.epoch == humanInputEpoch else { return true }
            let hasNewerHumanBoundary = currentBoundaries.contains { boundary in
                guard case .human(let generation) = boundary else {
                    return false
                }
                return generation > snapshot.generation
            }
            return !hasNewerHumanBoundary
        }
    }

    /// Confirms only input that exists in this epoch and retires its matching
    /// boundaries so a delayed hook cannot attribute the same submission again.
    private mutating func confirmHumanInputThroughGeneration(
        _ generation: UInt64
    ) {
        let confirmedGeneration = min(generation, humanInputGeneration)
        confirmedHumanInputGeneration = max(
            confirmedHumanInputGeneration,
            confirmedGeneration
        )
        pendingBoundaries.removeAll {
            guard case .human(let boundaryGeneration) = $0 else {
                return false
            }
            return boundaryGeneration <= confirmedGeneration
        }
    }

    /// Retires one possible app-owned hook before unmatched attribution may
    /// consume a human boundary, even when that app record sits behind it.
    private mutating func consumeEarliestProgrammaticBoundary() -> Bool {
        guard let index = pendingBoundaries.firstIndex(where: {
            switch $0 {
            case .programmatic, .retiredProgrammatic:
                return true
            case .human, .confirmedProgrammatic:
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
        let boundary = TerminalPromptSubmissionBoundary.human(
            generation: generation
        )
        if let firstConfirmedIndex = pendingBoundaries.firstIndex(where: {
            if case .confirmedProgrammatic = $0 { return true }
            return false
        }) {
            pendingBoundaries.insert(boundary, at: firstConfirmedIndex)
        } else {
            pendingBoundaries.append(boundary)
        }
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
        confirmHumanInputThroughGeneration(generation)
    }

    private mutating func retireProgrammaticBoundary(at index: Int) {
        defer { trimRetiredProgrammaticBoundaries() }
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

    /// Keeps replay tombstones bounded without evicting human ownership proof.
    private mutating func trimRetiredProgrammaticBoundaries() {
        var retiredCount = pendingBoundaries.reduce(into: 0) { count, boundary in
            if case .retiredProgrammatic(let boundaryCount) = boundary {
                count += boundaryCount
            }
        }
        while retiredCount > Self.maximumPendingBoundaries,
              let oldestIndex = pendingBoundaries.firstIndex(where: {
                  if case .retiredProgrammatic = $0 { return true }
                  return false
              }) {
            guard case .retiredProgrammatic(let boundaryCount) =
                    pendingBoundaries[oldestIndex] else { break }
            let excess = retiredCount - Self.maximumPendingBoundaries
            if boundaryCount <= excess {
                pendingBoundaries.remove(at: oldestIndex)
                retiredCount -= boundaryCount
            } else {
                pendingBoundaries[oldestIndex] = .retiredProgrammatic(
                    count: boundaryCount - excess
                )
                retiredCount -= excess
            }
        }
    }

    /// Bounds exact-hook replay tombstones without evicting human boundaries.
    private mutating func trimConfirmedProgrammaticBoundaries() {
        var confirmedCount = pendingBoundaries.reduce(into: 0) { count, boundary in
            if case .confirmedProgrammatic = boundary {
                count += 1
            }
        }
        while confirmedCount > Self.maximumPendingBoundaries,
              let oldestIndex = pendingBoundaries.firstIndex(where: {
                  if case .confirmedProgrammatic = $0 { return true }
                  return false
              }) {
            pendingBoundaries.remove(at: oldestIndex)
            hasEvictedProgrammaticTombstones = true
            confirmedCount -= 1
        }
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
