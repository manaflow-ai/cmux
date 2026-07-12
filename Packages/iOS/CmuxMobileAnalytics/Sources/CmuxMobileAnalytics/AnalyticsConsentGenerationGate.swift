internal import Foundation
internal import os

struct AnalyticsConsentSnapshot: Equatable, Sendable {
    let isEnabled: Bool
    let generation: UInt64
}

/// Synchronous consent state shared by fire-and-forget callers and the actor.
///
/// A generation makes an event captured before a revoke permanently stale even
/// if consent is enabled again before the actor drains its FIFO. Synchronizing
/// transport state inside the same critical section also closes the inverse
/// race where UserDefaults reads enabled before its notification re-enables the
/// uploader.
final class AnalyticsConsentGenerationGate: Sendable {
    private struct State: Sendable {
        var isEnabled: Bool
        var generation: UInt64 = 0

        var snapshot: AnalyticsConsentSnapshot {
            AnalyticsConsentSnapshot(isEnabled: isEnabled, generation: generation)
        }
    }

    // lint:allow lock - capture is synchronous/nonisolated, so an actor hop
    // would either block UI callers or reopen the consent-generation race.
    private let state: OSAllocatedUnfairLock<State>

    init(isEnabled: Bool) {
        state = .init(initialState: State(isEnabled: isEnabled))
    }

    func snapshot() -> AnalyticsConsentSnapshot {
        state.withLock { $0.snapshot }
    }

    /// Reconciles an observed provider value against the snapshot taken before
    /// reading it. If another thread changed consent during that read, the
    /// original snapshot is returned so the caller's submission stays stale.
    func synchronize(
        observedEnabled: Bool,
        basedOn base: AnalyticsConsentSnapshot,
        publish: @Sendable (AnalyticsConsentSnapshot) -> Void
    ) -> AnalyticsConsentSnapshot {
        state.withLock { state in
            guard state.generation == base.generation else { return base }
            guard state.isEnabled != observedEnabled else { return state.snapshot }
            state.isEnabled = observedEnabled
            state.generation &+= 1
            let updated = state.snapshot
            publish(updated)
            return updated
        }
    }

    func allows(_ snapshot: AnalyticsConsentSnapshot) -> Bool {
        state.withLock { state in
            state.isEnabled && state.generation == snapshot.generation
        }
    }
}
