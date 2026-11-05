public import Observation

/// `withObservationTracking` for a computation that also runs for reasons it does not observe (a notification, a
/// stale read), keeping one registration armed at a time. The registration has no cancel: it stays on every value the
/// computation read until one of them changes. Arming a new one on each run while the last had not fired piled them up,
/// and the first write of a shared value then cancelled every one on the main thread (cmuxterm-hq#6338, stack 2:
/// one per CLI read of the control snapshot before the launch restore, 2.4-2.6 s for the restore's first registry write).
///
/// While the armed registration has not fired, nothing the computation read changed, so a run over the same `shape`
/// (what the computation walks without observing it, such as windows, their mounted content and the active one) reads the same values and runs
/// untracked. A run over another shape arms again, so what it reads is tracked too.
@MainActor
public final class SingleArmedTracking {
    /// Set when a registration is armed, cleared by its change callback (not main-actor isolated).
    nonisolated private let armed = Atomic<Bool>(false)
    private var shape: [ObjectIdentifier] = []
    /// Registrations armed since init (tests, debug).
    public private(set) var armings = 0

    public init() {}

    /// `apply`, tracked unless the armed registration covers it; `onChange` runs once when a value the armed
    /// registration read is about to change (synchronously inside the mutation, like `withObservationTracking`'s).
    public func track<T>(shape: [ObjectIdentifier], _ apply: () -> T, onChange: @escaping @Sendable () -> Void) -> T {
        if armed.load(ordering: .acquiring), shape == self.shape { return apply() }
        armed.store(true, ordering: .releasing)
        self.shape = shape
        armings += 1
        return withObservationTracking(apply) { [weak self] in
            self?.armed.store(false, ordering: .releasing)
            onChange()
        }
    }
}
