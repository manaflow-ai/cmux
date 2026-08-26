/// Lets one caller stop waiting without cancelling pane-owned startup work.
final class SimulatorStartupWaitReceipt: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream.makeStream(of: Void.self)
        stream = pair.stream
        continuation = pair.continuation
    }

    func wait() async {
        for await _ in stream {}
    }

    func finish() {
        continuation.finish()
    }
}
