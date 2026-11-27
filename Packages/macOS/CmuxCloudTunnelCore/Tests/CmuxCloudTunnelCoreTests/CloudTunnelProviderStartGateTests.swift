import Testing
import CmuxCloudTunnelCore

@Suite("Cloud tunnel callback lifecycle", .timeLimit(.minutes(1)))
struct CloudTunnelProviderStartGateTests {
    private final class Adapter: CloudTunnelAdapter, Sendable {
        enum Operation: Sendable {
            case start(CloudTunnelProviderStartGate.Completion)
            case stop(CloudTunnelProviderStartGate.StopCompletion)
        }
        let operations: AsyncStream<Operation>
        let input: AsyncStream<Operation>.Continuation
        init() {
            let channel = AsyncStream<Operation>.makeStream()
            operations = channel.stream
            input = channel.continuation
        }
        func start(configuration: String, completion: @escaping CloudTunnelProviderStartGate.Completion) {
            input.yield(.start(completion))
        }
        func stop(completion: @escaping CloudTunnelProviderStartGate.StopCompletion) {
            input.yield(.stop(completion))
        }
    }

    @Test("duplicate platform starts invoke the adapter once and complete every request once")
    func duplicateStarts() async throws {
        let adapter = Adapter()
        let outcomes = AsyncStream<Int>.makeStream()
        let gate = CloudTunnelProviderStartGate(adapter: adapter)
        // Submit before scheduling the consumer, exactly as delayed OS delivery can do.
        gate.start(configuration: .success("same")) { error in #expect(error == nil); outcomes.continuation.yield(1) }
        gate.start(configuration: .success("same")) { error in #expect(error == nil); outcomes.continuation.yield(2) }
        let run = Task { await gate.run() }
        defer { run.cancel() }
        var operations = adapter.operations.makeAsyncIterator()
        var results = outcomes.stream.makeAsyncIterator()
        let operation = try #require(await operations.next())
        guard case let .start(complete) = operation else { Issue.record("Expected adapter start"); return }
        complete(nil)
        #expect(await results.next() == 1)
        #expect(await results.next() == 2)
        gate.start(configuration: .success("same")) { error in #expect(error == nil); outcomes.continuation.yield(3) }
        #expect(await results.next() == 3)
        gate.stop { outcomes.continuation.finish() }
        // A duplicate adapter invocation would appear here instead of stop.
        guard case let .stop(finish) = try #require(await operations.next()) else { Issue.record("Duplicate adapter start"); return }
        finish()
        await run.value
        #expect(await results.next() == nil)
    }

    @Test("stop waits for startup, rejects a replacement, then completes every callback once")
    func stopDuringStart() async throws {
        let adapter = Adapter()
        let outcomes = AsyncStream<String>.makeStream()
        let gate = CloudTunnelProviderStartGate(adapter: adapter)
        let run = Task { await gate.run() }
        defer { run.cancel() }
        var operations = adapter.operations.makeAsyncIterator()
        var results = outcomes.stream.makeAsyncIterator()
        gate.start(configuration: .success("config")) { e in #expect(e == .cancelled); outcomes.continuation.yield("cancelled") }
        guard case let .start(start) = try #require(await operations.next()) else { Issue.record("Expected start"); return }
        gate.stop { outcomes.continuation.yield("stop-1") }
        gate.stop { outcomes.continuation.yield("stop-2") }
        gate.start(configuration: .success("config")) { e in #expect(e == .cancelled); outcomes.continuation.yield("rejected") }
        // Rejection proves both preceding stop requests have reached the actor.
        #expect(await results.next() == "rejected")
        start(nil)
        #expect(await results.next() == "cancelled")
        guard case let .stop(stop) = try #require(await operations.next()) else { Issue.record("Expected teardown"); return }
        stop()
        await run.value
        #expect(await results.next() == "stop-1")
        #expect(await results.next() == "stop-2")
        gate.start(configuration: .success("config")) { e in #expect(e == .cancelled); outcomes.continuation.yield("closed") }
        #expect(await results.next() == "closed")
        outcomes.continuation.finish()
        #expect(await results.next() == nil)
    }

    @Test("an old adapter completion cannot complete a newer start generation")
    func staleCompletionAfterFailure() async throws {
        let adapter = Adapter()
        let outcomes = AsyncStream<Int>.makeStream()
        let gate = CloudTunnelProviderStartGate(adapter: adapter)
        let run = Task { await gate.run() }
        defer { run.cancel() }
        var operations = adapter.operations.makeAsyncIterator()
        var results = outcomes.stream.makeAsyncIterator()
        gate.start(configuration: .success("config")) { e in #expect(e == .invalidState); outcomes.continuation.yield(1) }
        guard case let .start(old) = try #require(await operations.next()) else { Issue.record("Expected start"); return }
        old(.invalidState)
        #expect(await results.next() == 1)
        gate.start(configuration: .success("config")) { e in #expect(e == nil); outcomes.continuation.yield(2) }
        guard case let .start(current) = try #require(await operations.next()) else { Issue.record("Expected retry"); return }
        old(.invalidConfiguration)
        current(nil)
        #expect(await results.next() == 2)
        gate.stop { outcomes.continuation.finish() }
        guard case let .stop(stop) = try #require(await operations.next()) else { Issue.record("Expected stop"); return }
        stop()
        await run.value
        #expect(await results.next() == nil)
    }

    @Test("a changed config replay is not reported as success for the old tunnel")
    func changedConfiguration() async throws {
        let adapter = Adapter()
        let outcomes = AsyncStream<Int>.makeStream()
        let gate = CloudTunnelProviderStartGate(adapter: adapter)
        let run = Task { await gate.run() }
        defer { run.cancel() }
        var operations = adapter.operations.makeAsyncIterator()
        var results = outcomes.stream.makeAsyncIterator()
        gate.start(configuration: .success("first")) { e in #expect(e == nil); outcomes.continuation.yield(1) }
        guard case let .start(start) = try #require(await operations.next()) else { Issue.record("Expected start"); return }
        gate.start(configuration: .success("changed")) { e in #expect(e == .configurationChanged); outcomes.continuation.yield(2) }
        #expect(await results.next() == 2)
        start(nil)
        #expect(await results.next() == 1)
        gate.start(configuration: .success("changed")) { e in #expect(e == .configurationChanged); outcomes.continuation.yield(3) }
        #expect(await results.next() == 3)
        gate.stop { outcomes.continuation.finish() }
        guard case let .stop(stop) = try #require(await operations.next()) else { Issue.record("Expected stop"); return }
        stop()
        await run.value
        #expect(await results.next() == nil)
    }

    @Test("a stop queued before the consumer starts cannot be overtaken by a start task")
    func stopBeforeStart() async {
        let adapter = Adapter()
        let outcomes = AsyncStream<Int>.makeStream()
        let gate = CloudTunnelProviderStartGate(adapter: adapter)
        gate.stop { outcomes.continuation.yield(1) }
        gate.start(configuration: .success("config")) { e in #expect(e == .cancelled); outcomes.continuation.yield(2) }
        await gate.run()
        outcomes.continuation.finish()
        var received: [Int] = []
        for await value in outcomes.stream { received.append(value) }
        #expect(received == [1, 2])
        adapter.input.finish()
        var operations = 0
        for await _ in adapter.operations { operations += 1 }
        #expect(operations == 0)
    }
}
