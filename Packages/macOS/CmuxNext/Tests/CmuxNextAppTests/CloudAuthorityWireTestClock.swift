import Foundation

actor CloudAuthorityWireTestClock {
    private let arrivals = AsyncStream<Duration>.makeStream()
    private var timers: [(Duration, AsyncStream<Void>.Continuation)] = []

    func sleep(_ duration: Duration) async throws {
        let gate = AsyncStream<Void>.makeStream()
        timers.append((duration, gate.continuation))
        arrivals.continuation.yield(duration)
        var iterator = gate.stream.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
    }
    func nextTimer() async -> Duration? { var iterator = arrivals.stream.makeAsyncIterator(); return await iterator.next() }
    func waitForTimer(_ duration: Duration) async throws {
        while let next = await nextTimer() { if next == duration { return } }
        throw CancellationError()
    }
    func fire(_ duration: Duration) {
        for timer in timers where timer.0 == duration { timer.1.yield(()); timer.1.finish() }
    }
    func finish() { for timer in timers { timer.1.finish() }; arrivals.continuation.finish() }
}
