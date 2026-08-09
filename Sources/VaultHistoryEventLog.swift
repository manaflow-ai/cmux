import CmuxVaultHistory
import Foundation
import Observation

/// Main-actor owner that coordinates lifecycle recording and History refreshes.
///
/// The app composition root constructs exactly one instance and injects it into
/// every lifecycle producer and History consumer. ``phase`` is the single gate
/// for launch, restore, and termination suppression; accepted events serialize
/// through the actor-backed store before ``revision`` changes.
@MainActor
@Observable
final class VaultHistoryEventLog {
    private(set) var revision: UInt64 = 0
    private(set) var phase: VaultHistoryRecordingPhase

    private let store: any VaultHistoryEventStoring
    private var pendingRecordTask: Task<Void, Never>?

    init(
        store: any VaultHistoryEventStoring,
        phase: VaultHistoryRecordingPhase = .launching
    ) {
        self.store = store
        self.phase = phase
    }

    func transition(to phase: VaultHistoryRecordingPhase) {
        self.phase = phase
    }

    func record(_ event: VaultHistoryEvent) {
        guard phase == .active else { return }
        let store = store
        let previous = pendingRecordTask
        pendingRecordTask = Task(priority: .utility) { [weak self] in
            await previous?.value
            guard !Task.isCancelled,
                  await store.append(event),
                  let self else {
                return
            }
            self.revision &+= 1
        }
    }

    func recentEvents(limit: Int = Int.max) async -> [VaultHistoryEvent] {
        await store.recentEvents(limit: limit)
    }

    func flushPendingRecords() async {
        await pendingRecordTask?.value
    }
}
