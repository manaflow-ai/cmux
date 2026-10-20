actor CloudObservedAuthorityTestGate {
    private let held = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var pending: CheckedContinuation<Void, Never>?

    func hold() async { await withCheckedContinuation { pending = $0; held.continuation.yield(()) } }
    func waitUntilHeld() async { var iterator = held.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { pending?.resume(); pending = nil }
}
