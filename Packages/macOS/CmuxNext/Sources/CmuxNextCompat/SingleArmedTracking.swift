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
///
/// One registration counts one change. The system takes the callbacks of a value's change before it calls the
/// first of them, so a registration that read two values has its callback called two times when a callback before
/// it, in the change of the first value, moves the second one (a kept part's callback moves its owner's cell,
/// ``KeptParts``). The second call does nothing here (``OneObservationCall``).
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
    public func track<T>(shape: [ObjectIdentifier], _ apply: () -> T, onChange: @escaping @Sendable () -> Void,
                         fileID: StaticString = #fileID, line: UInt = #line) -> T {
        if armed.load(ordering: .acquiring), shape == self.shape { return apply() }
        armed.store(true, ordering: .releasing)
        self.shape = shape
        armings += 1
        let instance = ObjectIdentifier(self), site = ObservationSite(fileID: fileID, line: line)
        let call = OneObservationCall()
        return site.tracking {
            withObservationTracking(apply) { [weak self] in
                guard call.isFirst() else { return }
                site.woke()
                ObservationWakes.record(site: site, instance: instance)
                self?.armed.store(false, ordering: .releasing)
                onChange()
            }
        }
    }
}

/// The first call of one registration's change callback, for a callback that counts one change: `isFirst()` is
/// true one time. Sendable: a change callback is not isolated.
final class OneObservationCall: Sendable {
    private let called = Atomic<Bool>(false)

    /// True at the first call, false at each call after it.
    func isFirst() -> Bool { !called.exchange(true, ordering: .acquiringAndReleasing) }

    /// A change callback that runs `body` at its first call and does nothing at each call after it.
    static func once(_ body: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let call = OneObservationCall()
        return { if call.isFirst() { body() } }
    }
}
