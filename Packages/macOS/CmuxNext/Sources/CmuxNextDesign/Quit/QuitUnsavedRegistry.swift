import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Foundation
import os
public import CmuxNextDesignTokens

/// The one quit hook for unsaved state (R96). The registry holds every
/// participant weakly; `save` runs every save concurrently, each bounded by
/// its own `userBlocking` deadline (``ComponentDeadline``: a person waits on
/// the quit; a timeout ends the wait, not a write already in progress); a
/// saved or discarded participant's recovery draft goes away, a failed one
/// keeps it.
@MainActor
public final class QuitUnsavedRegistry {
    /// The longest deadline a participant may declare.
    public static let maxDeadline: Duration = .seconds(30)

    private struct Entry {
        let token: Int
        weak var participant: (any QuitUnsavedParticipant)?
    }

    private let deadlines: ComponentDeadlines
    private let drafts: RecoveryDraftStore?
    private var entries: [Entry] = []
    private var nextToken = 1

    /// - Parameters:
    ///   - deadlines: Where each save's limit runs: the app's deadline scheduler (``ComponentDeadlines/on(_:)``);
    ///     by default the continuous clock.
    ///   - drafts: The recovery drafts a saved or discarded participant drops.
    public init(deadlines: ComponentDeadlines = .clock(ContinuousClock()), drafts: RecoveryDraftStore? = nil) {
        self.deadlines = deadlines
        self.drafts = drafts
    }

    /// Registers `participant` weakly. An id that is not
    /// `file:<host id>:<absolute path>` (see `QuitParticipantID`) is refused:
    /// it is logged by its shape only and the returned registration is
    /// inactive (`isActive` false).
    @discardableResult
    public func register(_ participant: any QuitUnsavedParticipant) -> QuitUnsavedRegistration {
        let id = participant.quitParticipantID
        guard QuitParticipantID.isValid(id) else {
            Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
                .error("refused quit participant id (\(QuitParticipantID.shape(id), privacy: .public))")
            return QuitUnsavedRegistration(onCancel: nil)
        }
        let token = nextToken
        nextToken += 1
        entries.append(Entry(token: token, participant: participant))
        return QuitUnsavedRegistration { [weak self] in self?.entries.removeAll { $0.token == token } }
    }

    /// Participants with unsaved changes, one per id, in registration order.
    public func unsaved() -> [any QuitUnsavedParticipant] {
        entries.removeAll { $0.participant == nil }
        var seen: Set<String> = []
        return entries.compactMap(\.participant).filter { $0.hasUnsavedChanges && seen.insert($0.quitParticipantID).inserted }
    }

    /// Saves `participants` concurrently. `deadlineCap` lowers every
    /// deadline (non-interactive quits use 3 s). `saving` reports the titles
    /// still saving after each change.
    public func save(_ participants: [any QuitUnsavedParticipant], deadlineCap: Duration? = nil,
                     saving: (([String]) -> Void)? = nil) async -> [QuitFlushOutcome] {
        var pending = participants.map(\.quitTitle)
        saving?(pending)
        // Every save starts now, each racing its own limit; the results are then collected in order.
        let flushes = participants.map { participant in
            let deadline = min(participant.quitFlushDeadline, deadlineCap ?? Self.maxDeadline, Self.maxDeadline)
            return QuitFlush(participant, within: deadline, limit: deadlines.deadline(owner: "quit.flush", workClass: .userBlocking))
        }
        var outcomes: [QuitFlushOutcome] = []
        for flush in flushes {
            let outcome = await flush.outcome()
            outcomes.append(outcome)
            if let index = pending.firstIndex(of: outcome.title) { pending.remove(at: index) }
            saving?(pending)
        }
        for outcome in outcomes where outcome.result == .saved { await drafts?.remove(id: outcome.id) }
        return outcomes
    }

    /// "Don't Save": discards each and removes its draft.
    public func discard(_ participants: [any QuitUnsavedParticipant]) async {
        for participant in participants {
            await participant.discardForQuit()
            await drafts?.remove(id: participant.quitParticipantID)
        }
    }
}

/// Ends a registration; the registry also drops a participant that deallocates.
@MainActor
public final class QuitUnsavedRegistration {
    private var onCancel: (() -> Void)?
    /// False after `cancel`, and for a participant the registry refused.
    public var isActive: Bool { onCancel != nil }

    init(onCancel: (() -> Void)?) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// One participant's save raced against its limit: the first of the two answers. The write runs in its own
/// task, so a timeout ends the wait and never cancels a write in progress.
@MainActor
final class QuitFlush {
    let id: String
    let title: String
    private let limit: any ComponentDeadline
    private var result: QuitFlushOutcome.Result?
    private var waiter: OnceContinuation<QuitFlushOutcome.Result, OnceContinuationError>?

    /// Starts the write of `participant` and its limit, `deadline` from now, on `limit`.
    init(_ participant: any QuitUnsavedParticipant, within deadline: Duration, limit: any ComponentDeadline) {
        id = participant.quitParticipantID
        title = participant.quitTitle
        self.limit = limit
        limit.schedule(after: deadline) { [weak self] in self?.finish(.timedOut) }
        // main-hop-allow: the write is the participant's main-actor async save, started at once in its own task so
        // that the limit ends only the wait; the task only awaits it and records the answer in its resume
        Task { @MainActor [weak self] in
            do {
                try await participant.flushForQuit()
                self?.finish(.saved)
            } catch let error as QuitFlushError {
                self?.finish(.failed(error.reason))
            } catch {
                self?.finish(.failed(error.localizedDescription))
            }
        }
    }

    /// The first answer: the write's, or ``QuitFlushOutcome/Result/timedOut`` at the limit.
    func outcome() async -> QuitFlushOutcome {
        let result: QuitFlushOutcome.Result
        if let answered = self.result {
            result = answered
        } else {
            // A wait whose answer was dropped (neither the write nor the limit resumed it) counts as timed out.
            result = (try? await withOnceContinuation { (continuation: OnceContinuation<QuitFlushOutcome.Result, OnceContinuationError>) in
                self.waiter = continuation
            }) ?? .timedOut
        }
        return QuitFlushOutcome(id: id, title: title, result: result)
    }

    private func finish(_ result: QuitFlushOutcome.Result) {
        guard self.result == nil else { return }
        self.result = result
        limit.cancel()
        waiter?.resume(returning: result)
        waiter = nil
    }
}
