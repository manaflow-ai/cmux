import Foundation

/// A single-consumer async message queue bounded by aggregate payload bytes.
///
/// Web Inspector publishes its initial application census as a burst. A
/// one-element `AsyncStream` drops valid protocol messages before its consumer
/// can run, while a count-based queue can retain several maximum-sized frames.
/// This queue preserves every message that fits under one explicit byte ceiling.
struct SimulatorWebInspectorMessageStream: AsyncSequence, Sendable {
    typealias Element = Data
    typealias AsyncIterator = SimulatorWebInspectorMessageIterator

    let storage: SimulatorWebInspectorMessageStorage

    init(maximumBufferedBytes: Int, initiallyFinished: Bool = false) {
        storage = SimulatorWebInspectorMessageStorage(
            maximumBufferedBytes: maximumBufferedBytes,
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
