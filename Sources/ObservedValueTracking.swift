import Combine
import Foundation
import Observation

// The Observation runtime retains a registered `onChange` callback until one of
// the tracked properties mutates. To make cancellation release the caller's
// read/onChange closures and the last delivered value immediately (matching
// Combine's AnyCancellable semantics), all captures live on a coordinator that
// the runtime callback references only weakly. The token strongly owns the
// coordinator, so `cancel()` or dropping the token frees every capture even
// while the observed value stays idle; the runtime's pending callback then
// no-ops against a nil weak reference.
@MainActor
private protocol ObservedValueCancellation: AnyObject, Sendable {
    func cancelObservation()
    /// Synchronous, thread-safe "cancelled" mark. `cancel()` sets this before
    /// (possibly asynchronously) running `cancelObservation`, so a re-arm task
    /// that was already queued on the main actor cannot deliver after
    /// `cancel()` has returned on another thread.
    nonisolated func markCancelled()
}

/// Lock-guarded because it must be settable synchronously from whatever thread
/// calls `cancel()` (Combine's `receiveCancel` contract) and readable on the
/// main actor; an actor hop here would reintroduce the post-cancel window.
private final class ObservedValueCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
private final class ObservedValueCoordinator<V: Equatable>: ObservedValueCancellation {
    private var read: (@MainActor () -> V)?
    private var onChange: (@MainActor (V) -> Void)?
    private var hasDelivered = false
    private var lastDelivered: V?
    private let cancelFlag = ObservedValueCancelFlag()

    nonisolated func markCancelled() {
        cancelFlag.set()
    }

    init(
        read: @escaping @MainActor () -> V,
        onChange: @escaping @MainActor (V) -> Void
    ) {
        self.read = read
        self.onChange = onChange
    }

    func cancelObservation() {
        read = nil
        onChange = nil
        lastDelivered = nil
    }

    func arm(shouldDeliver: Bool) {
        guard !cancelFlag.isSet, let read else { return }
        let value = withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.arm(shouldDeliver: true)
            }
        }

        guard self.read != nil, !cancelFlag.isSet else { return }
        if shouldDeliver {
            deliver(value)
        }
    }

    private func deliver(_ value: V) {
        if hasDelivered, lastDelivered == value {
            return
        }
        hasDelivered = true
        lastDelivered = value
        onChange?(value)
    }
}

// Cancellation releases the coordinator, which frees the caller's captures and
// turns any pending runtime callback into a no-op. Combine's `receiveCancel`
// runs on whatever thread called `cancel()` on the subscription, so the
// coordinator handoff is lock-guarded and the main-actor teardown hops when
// cancellation arrives off-main. Dropping the token without cancelling releases
// the same reference in deinit.
final class ObservationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinatorStorage: (any ObservedValueCancellation)?

    fileprivate init(coordinator: any ObservedValueCancellation) {
        coordinatorStorage = coordinator
    }

    private func takeCoordinator() -> (any ObservedValueCancellation)? {
        lock.lock()
        defer { lock.unlock() }
        let coordinator = coordinatorStorage
        coordinatorStorage = nil
        return coordinator
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return coordinatorStorage == nil
    }

    func cancel() {
        guard let coordinator = takeCoordinator() else { return }
        // Synchronously fence off any re-arm task already queued on the main
        // actor, so no delivery can happen after this call returns even when
        // the capture teardown below has to hop actors.
        coordinator.markCancelled()
        if Thread.isMainThread {
            MainActor.assumeIsolated { coordinator.cancelObservation() }
        } else {
            Task { @MainActor in coordinator.cancelObservation() }
        }
    }
}

@MainActor
func observeTrackedValue<V: Equatable>(
    initial: Bool = true,
    _ read: @escaping @MainActor () -> V,
    onChange: @escaping @MainActor (V) -> Void
) -> ObservationToken {
    let coordinator = ObservedValueCoordinator(read: read, onChange: onChange)
    coordinator.arm(shouldDeliver: initial)
    return ObservationToken(coordinator: coordinator)
}

@MainActor
func observedValuesPublisher<V: Equatable>(
    _ read: @escaping @MainActor () -> V
) -> AnyPublisher<V, Never> {
    Deferred {
        let subject = CurrentValueSubject<V, Never>(read())
        var token: ObservationToken?
        token = observeTrackedValue(initial: false, read) { value in
            subject.send(value)
        }
        return subject
            .handleEvents(
                receiveCompletion: { _ in
                    token?.cancel()
                    token = nil
                },
                receiveCancel: {
                    token?.cancel()
                    token = nil
                }
            )
            .eraseToAnyPublisher()
    }
    .eraseToAnyPublisher()
}
