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
    private var pendingRecordCount = 0

    /// Whether accepted records are still queued or being persisted.
    var hasPendingRecords: Bool {
        pendingRecordCount > 0
    }

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
        pendingRecordCount += 1
        pendingRecordTask = Task(priority: .utility) { [weak self] in
            await previous?.value
            let didAppend: Bool
            if Task.isCancelled {
                didAppend = false
            } else {
                didAppend = await store.append(event)
            }
            guard let self else { return }
            if didAppend {
                self.revision &+= 1
            }
            self.pendingRecordCount -= 1
            if self.pendingRecordCount == 0 {
                self.pendingRecordTask = nil
            }
        }
    }

    func recentEvents(limit: Int = Int.max) async -> [VaultHistoryEvent] {
        await store.recentEvents(limit: limit)
    }

    func flushPendingRecords() async {
        await pendingRecordTask?.value
    }
}
