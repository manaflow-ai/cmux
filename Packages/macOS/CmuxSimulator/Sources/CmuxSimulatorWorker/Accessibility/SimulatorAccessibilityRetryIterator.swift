import Foundation

struct SimulatorAccessibilityRetryIterator: AsyncIteratorProtocol {
    private let delays: [Duration]
    private let nextEvent: @Sendable (Duration) async throws -> Void
    private var index = 0

    init(
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
