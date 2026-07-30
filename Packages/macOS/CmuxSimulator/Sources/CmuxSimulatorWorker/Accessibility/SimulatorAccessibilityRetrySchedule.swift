import Foundation

/// Emits the bounded connection attempts allowed for one accessibility request.
///
/// The private Simulator accessibility translator exposes no readiness
/// callback. Keeping its backoff inside an async sequence gives the actor one
/// cancellation-aware scheduling boundary instead of embedding sleeps in the
/// request loop.
struct SimulatorAccessibilityRetrySchedule: AsyncSequence, Sendable {
    typealias Element = Void

    private let delays: [Duration]
    private let nextEvent: @Sendable (Duration) async throws -> Void

    init(
        delays: [Duration] = [
            .zero,
            .milliseconds(100),
            .milliseconds(300),
            .milliseconds(700),
            .milliseconds(1_500),
        ],
        nextEvent: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.delays = delays
        self.nextEvent = nextEvent
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(delays: delays, nextEvent: nextEvent)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        private let delays: [Duration]
        private let nextEvent: @Sendable (Duration) async throws -> Void
        private var index = 0

        fileprivate init(
            delays: [Duration],
            nextEvent: @escaping @Sendable (Duration) async throws -> Void
        ) {
            self.delays = delays
            self.nextEvent = nextEvent
        }

        mutating func next() async throws -> Void? {
            guard index < delays.count else { return nil }
            try Task.checkCancellation()
            let delay = delays[index]
            index += 1
            if delay != .zero {
                try await nextEvent(delay)
            }
            return ()
        }
    }
}
