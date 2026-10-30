import CmuxNextCompat
@testable import CmuxNextTerminal
import Dispatch
import Foundation
import GhosttyNextKit
import Testing

/// The attach reader feeds the output lane directly (``TerminalOutputLane/enqueueEcho(_:flow:wake:)``):
/// a chunk is queued at once, and above the lane's capacity the reader is told to wait and
/// woken exactly once, when the backlog drains to the high water or the lane closes. The lane's parse is the
/// test's recorder, so no Ghostty surface is made.
@Suite(.timeLimit(.minutes(1))) struct TerminalOutputLaneEchoTests {
    static let surface = TerminalOutputLaneHangScopeTests.surface

    /// Counts the wakes a lane calls.
    private nonisolated final class Wakes: Sendable {
        private let count = Mutex(0)
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            (stream, continuation) = AsyncStream<Void>.makeStream()
        }

        var wake: @Sendable () -> Void {
            { [self] in
                count.withLock { $0 += 1 }
                continuation.yield()
            }
        }
        var total: Int { count.withLock { $0 } }
        func next() async {
            for await _ in stream { return }
        }
    }

    @Test func belowTheHighWaterTheReaderGoesOn() async {
        let (parsedChunks, parsed) = AsyncStream.makeStream(of: Data.self)
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.echo-below", highWater: 16) { _, data in
            parsed.yield(data)
        }
        defer { lane.close {} }
        let wakes = Wakes()
        #expect(!lane.enqueueEcho(Data("abc".utf8), flow: nil, wake: wakes.wake))
        var iterator = parsedChunks.makeAsyncIterator()
        #expect(await iterator.next() == Data("abc".utf8))
        await lane.drained()
        #expect(wakes.total == 0)
    }

    @Test func aboveTheHighWaterTheReaderWaitsForOneWake() async {
        let gate = DispatchSemaphore(value: 0)
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.echo-above", highWater: 2) { _, _ in
            gate.wait() // holds the parse, so the backlog stays above the high water
        }
        defer { lane.close {} }
        let wakes = Wakes()
        #expect(lane.enqueueEcho(Data("abcd".utf8), flow: nil, wake: wakes.wake))
        #expect(wakes.total == 0)
        gate.signal()
        await wakes.next()
        await lane.drained()
        #expect(wakes.total == 1)
        #expect(lane.pendingBytes == 0)
    }

    @Test func closingWakesAWaitingReader() async {
        let gate = DispatchSemaphore(value: 0)
        let (started, startedSignal) = AsyncStream.makeStream(of: Void.self)
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.echo-close", highWater: 1) { _, data in
            if data == Data("first".utf8) {
                startedSignal.yield()
                gate.wait()
            }
        }
        let wakes = Wakes()
        #expect(lane.enqueueEcho(Data("first".utf8), flow: nil, wake: wakes.wake))
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let closed = Task.detached { lane.close {} }
        await wakes.next()
        #expect(wakes.total == 1)
        gate.signal()
        await closed.value
    }
}
