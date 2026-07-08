import Combine
import Foundation
import Observation

// Cancellation is a single boolean read and written from main-actor APIs, with
// deinit allowed to mark it cancelled if the owner drops the token.
final class ObservationToken: @unchecked Sendable {
    // Safe because observeValue uses the token on the main actor; deinit only
    // performs the same terminal cancellation write.
    private nonisolated(unsafe) var isCancelledStorage = false

    @MainActor
    var isCancelled: Bool {
        isCancelledStorage
    }

    @MainActor
    func cancel() {
        isCancelledStorage = true
    }

    deinit {
        isCancelledStorage = true
    }
}

@MainActor
func observeValue<V: Equatable>(
    initial: Bool = true,
    _ read: @escaping @MainActor () -> V,
    onChange: @escaping @MainActor (V) -> Void
) -> ObservationToken {
    let token = ObservationToken()
    var hasDelivered = false
    var lastDelivered: V?

    func deliver(_ value: V) {
        if hasDelivered, lastDelivered == value {
            return
        }
        hasDelivered = true
        lastDelivered = value
        onChange(value)
    }

    func arm(token: ObservationToken, shouldDeliver: Bool) {
        guard !token.isCancelled else { return }
        let value = withObservationTracking {
            read()
        } onChange: {
            Task { @MainActor [weak token] in
                guard let token, !token.isCancelled else { return }
                arm(token: token, shouldDeliver: true)
            }
        }

        guard !token.isCancelled else { return }
        if shouldDeliver {
            deliver(value)
        }
    }

    arm(token: token, shouldDeliver: initial)
    return token
}

@MainActor
func observedValuesPublisher<V: Equatable>(
    _ read: @escaping @MainActor () -> V
) -> AnyPublisher<V, Never> {
    Deferred {
        let subject = CurrentValueSubject<V, Never>(read())
        var token: ObservationToken?
        token = observeValue(initial: false, read) { value in
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
