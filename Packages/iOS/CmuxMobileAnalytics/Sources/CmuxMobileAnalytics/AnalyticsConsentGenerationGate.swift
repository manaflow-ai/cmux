/// Synchronous consent state shared by fire-and-forget callers and the actor.
///
/// A generation makes an event captured before a revoke permanently stale even
/// if consent is enabled again before the actor drains its FIFO. Synchronizing
/// transport state inside the same critical section also closes the inverse
/// race where UserDefaults reads enabled before its notification re-enables the
/// uploader.
final class AnalyticsConsentGenerationGate: Sendable {
    private let state: AnalyticsCriticalState<(isEnabled: Bool, generation: UInt64)>

    init(isEnabled: Bool) {
        state = AnalyticsCriticalState(
            initialValue: (isEnabled: isEnabled, generation: 0)
        )
    }

    func snapshot() -> AnalyticsConsentSnapshot {
        state.withCriticalRegion {
            AnalyticsConsentSnapshot(isEnabled: $0.isEnabled, generation: $0.generation)
        }
    }

    /// Reconciles an observed provider value against the snapshot taken before
    /// reading it. If another thread changed consent during that read, the
    /// original snapshot is returned so the caller's submission stays stale.
    func synchronize(
        observedEnabled: Bool,
        basedOn base: AnalyticsConsentSnapshot,
        publish: @Sendable (AnalyticsConsentSnapshot) -> Void
    ) -> AnalyticsConsentSnapshot {
        state.withCriticalRegion { state in
            guard state.generation == base.generation else { return base }
            guard state.isEnabled != observedEnabled else {
                return AnalyticsConsentSnapshot(
                    isEnabled: state.isEnabled,
                    generation: state.generation
                )
            }
            state.isEnabled = observedEnabled
            state.generation &+= 1
            let updated = AnalyticsConsentSnapshot(
                isEnabled: state.isEnabled,
                generation: state.generation
            )
            publish(updated)
            return updated
        }
    }

    func allows(_ snapshot: AnalyticsConsentSnapshot) -> Bool {
        state.withCriticalRegion { state in
            state.isEnabled && state.generation == snapshot.generation
        }
    }
}
