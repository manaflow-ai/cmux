import Foundation

/// A single-consumer async message queue bounded by payload bytes and message count.
///
/// Web Inspector publishes its initial application census as a burst. A
/// one-element `AsyncStream` drops valid protocol messages before its consumer
/// can run, while a byte-only queue can retain unlimited tiny allocations. This
/// queue preserves every valid message that fits under both explicit ceilings.
struct SimulatorWebInspectorMessageStream: AsyncSequence, Sendable {
    typealias Element = Data
    typealias AsyncIterator = SimulatorWebInspectorMessageIterator
    private static let defaultMaximumBufferedMessages = 4_096

    let storage: SimulatorWebInspectorMessageStorage

    init(
        maximumBufferedBytes: Int,
        maximumBufferedMessages: Int = Self.defaultMaximumBufferedMessages,
        initiallyFinished: Bool = false
    ) {
        storage = SimulatorWebInspectorMessageStorage(
            maximumBufferedBytes: maximumBufferedBytes,
            maximumBufferedMessages: maximumBufferedMessages,
            initiallyFinished: initiallyFinished
        )
    }

    func makeAsyncIterator() -> SimulatorWebInspectorMessageIterator {
        SimulatorWebInspectorMessageIterator(storage: storage)
    }

    func yield(_ data: Data) async -> SimulatorWebInspectorMessageYieldResult {
        await storage.yield(data)
    }

    func finish() async {
        await storage.finish()
    }
}
