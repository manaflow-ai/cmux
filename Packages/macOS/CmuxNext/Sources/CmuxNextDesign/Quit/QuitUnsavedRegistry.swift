import CmuxNextWakeups
import Foundation

/// The one quit hook for unsaved state (R96). The registry holds every
/// participant weakly; `save` runs every save concurrently, each bounded by
/// its own deadline on the injected clock (a timeout ends the wait, not a
/// write already in progress); a saved or discarded participant's recovery
/// draft goes away, a failed one keeps it.
@MainActor
public final class QuitUnsavedRegistry {
    public static let shared = QuitUnsavedRegistry()
    /// The longest deadline a participant may declare.
    public static let maxDeadline: Duration = .seconds(30)

    private struct Entry {
        let token: Int
        weak var participant: (any QuitUnsavedParticipant)?
    }

    private let clock: any Clock<Duration>
    private let drafts: RecoveryDraftStore?
    private var entries: [Entry] = []
    private var nextToken = 1

    public init(clock: any Clock<Duration> = ContinuousClock(), drafts: RecoveryDraftStore? = .shared) {
        self.clock = clock
        self.drafts = drafts
    }

    @discardableResult
    public func register(_ participant: any QuitUnsavedParticipant) -> QuitUnsavedRegistration {
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
        // Every save starts now (each in its own main-actor task with its
        // own deadline); the results are then collected in order.
        let saves = participants.map { participant in
            let deadline = min(participant.quitFlushDeadline, deadlineCap ?? Self.maxDeadline, Self.maxDeadline)
            return Task { @MainActor in await self.saveOne(participant, within: deadline) }
        }
        var outcomes: [QuitFlushOutcome] = []
        for save in saves {
            let outcome = await save.value
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

    /// One save raced against its deadline. The write runs in its own task,
    /// so a timeout never cancels a write in progress.
    private func saveOne(_ participant: any QuitUnsavedParticipant, within deadline: Duration) async -> QuitFlushOutcome {
        let id = participant.quitParticipantID
        let title = participant.quitTitle
        let timer = DemandTimer(owner: "quit-flush", clock: clock)
        let result: QuitFlushOutcome.Result = await withCheckedContinuation { continuation in
            let once = QuitFlushOnce(continuation)
            timer.schedule(after: deadline) { @MainActor in once.resume(.timedOut) }
            Task { @MainActor in
                do {
                    try await participant.flushForQuit()
                    once.resume(.saved)
                } catch let error as QuitFlushError {
                    once.resume(.failed(error.reason))
                } catch {
                    once.resume(.failed(error.localizedDescription))
                }
            }
        }
        timer.cancel()
        return QuitFlushOutcome(id: id, title: title, result: result)
    }
}

/// Ends a registration; the registry also drops a participant that deallocates.
@MainActor
public final class QuitUnsavedRegistration {
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// Resumes a save's continuation once (the save or its deadline, first).
@MainActor
final class QuitFlushOnce {
    private var continuation: CheckedContinuation<QuitFlushOutcome.Result, Never>?

    init(_ continuation: CheckedContinuation<QuitFlushOutcome.Result, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: QuitFlushOutcome.Result) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
