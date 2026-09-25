import Combine
import Foundation
import Observation
import os

// Observation keeps an onChange callback registered until a tracked property
// mutates. The cancellation flag is therefore set synchronously before the
// main-actor teardown can run, so a queued re-arm cannot deliver after cancel.
private final class ObservedValueCancellationFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func markCancelled() {
        state.withLock { $0 = true }
    }

    var isCancelled: Bool {
        state.withLock { $0 }
    }
}

@MainActor
private protocol ObservedValueCancellation: AnyObject, Sendable {
    nonisolated func markCancelled()
    func cancelObservation()
}

@MainActor
private final class ObservedValueCoordinator<Value: Equatable>: ObservedValueCancellation {
    private var read: (@MainActor () -> Value)?
    private var onChange: (@MainActor (Value) -> Void)?
    private var lastDelivered: Value?
    private var hasDelivered = false
    private let cancellationFlag = ObservedValueCancellationFlag()

    init(
        read: @escaping @MainActor () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) {
        self.read = read
        self.onChange = onChange
    }

    nonisolated func markCancelled() {
        cancellationFlag.markCancelled()
    }

    func cancelObservation() {
        read = nil
        onChange = nil
        lastDelivered = nil
    }

    func arm(shouldDeliver: Bool) {
        guard !cancellationFlag.isCancelled, let read else { return }
        let value = withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.arm(shouldDeliver: true)
            }
        }

        guard !cancellationFlag.isCancelled, self.read != nil else { return }
        if shouldDeliver, hasDelivered == false || shouldDeliver && lastDelivered != value {
            hasDelivered = true
            lastDelivered = value
            onChange?(value)
        }
    }
}

/// Cancels one Observation tracking registration and releases its closures.
final class ObservationToken: @unchecked Sendable {
    // The lock only protects the one-time handoff of the coordinator from a
    // synchronous cancellation callback; domain state remains main-actor owned.
    private let coordinatorStorage = OSAllocatedUnfairLock<AnyObject?>(initialState: nil)

    fileprivate init(coordinator: AnyObject) {
        coordinatorStorage.withLock { $0 = coordinator }
    }

    var isCancelled: Bool {
        coordinatorStorage.withLock { $0 == nil }
    }

    fileprivate static func start<Value: Equatable>(
        initial: Bool,
        read: @escaping @MainActor () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) -> ObservationToken {
        let coordinator = ObservedValueCoordinator(read: read, onChange: onChange)
        coordinator.arm(shouldDeliver: initial)
        return ObservationToken(coordinator: coordinator)
    }

    func cancel() {
        let coordinator = coordinatorStorage.withLock { storage -> AnyObject? in
            defer { storage = nil }
            return storage
        }
        guard let cancellation = coordinator as? any ObservedValueCancellation else { return }
        cancellation.markCancelled()
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                cancellation.cancelObservation()
            }
        } else {
            Task { @MainActor in
                cancellation.cancelObservation()
            }
        }
    }

    deinit {
        cancel()
    }
}

/// Keeps one observation registration alive while subscribers come and go.
///
/// A separate `withObservationTracking` registration per subscriber leaves a
/// dormant registrar entry whenever that subscriber is cancelled before the
/// source mutates. This channel owns one registration and fans out its latest
/// value through a replaying subject, so subscriber churn never creates more
/// than one registrar entry for the channel's source.
@MainActor
final class ObservedValueTracking<Value: Equatable> {
    private let read: @MainActor () -> Value

    init(read: @escaping @MainActor () -> Value) {
        self.read = read
    }

    var publisher: AnyPublisher<Value, Never> {
        Deferred { [read] in
            let subject = CurrentValueSubject(read())
            var token: ObservationToken?
            token = ObservationToken.start(initial: false, read: read) { value in
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
}
