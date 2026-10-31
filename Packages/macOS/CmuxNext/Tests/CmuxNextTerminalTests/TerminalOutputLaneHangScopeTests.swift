import CmuxNextCompat
@testable import CmuxNextTerminal
@testable import CmuxNextTrace
import Dispatch
import Foundation
import GhosttyNextKit
import Testing

/// Each output chunk's parse on its TerminalOutputLane is one `terminal.feed` hang scope of 100 ms, and
/// a chunk waiting behind an earlier one on the lane's queue is in none
/// (plans/cmux-next/chrome-parity/p02-threads.md, task 017). The lane's parse is the test's recorder,
/// so no Ghostty surface is made: the surface pointer is never dereferenced.
@Suite(.timeLimit(.minutes(1))) struct TerminalOutputLaneHangScopeTests {
    static var surface: ghostty_surface_t { unsafeBitCast(UInt(0x1000), to: ghostty_surface_t.self) }
    static let feed = FeedHangWatch.Scope(name: "terminal.feed", deadline: .milliseconds(100))

    @Test func eachChunkIsOneScopeAndTheQueueWaitIsNone() async {
        let hangs = FeedHangWatch()
        let gate = DispatchSemaphore(value: 0)
        let (parsedChunks, parsed) = AsyncStream.makeStream(of: [FeedHangWatch.Scope].self)
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.terminal-feed", hangs: hangs) { _, data in
            parsed.yield(hangs.open)
            if data == Data("first".utf8) { gate.wait() }  // holds the lane while the second chunk waits
        }
        defer { lane.close {} }
        #expect(hangs.lanes == ["terminal.feed"])
        lane.processOutput(Data("first".utf8))
        lane.processOutput(Data("second".utf8))
        var iterator = parsedChunks.makeAsyncIterator()

        #expect(await iterator.next() == [Self.feed])
        #expect(hangs.entered == [Self.feed], "the chunk waiting on the lane's queue opened a scope")
        gate.signal()
        #expect(await iterator.next() == [Self.feed])
        await lane.drained()

        #expect(hangs.entered == [Self.feed, Self.feed])
        #expect(hangs.open.isEmpty)
    }

    /// With no watcher the lane still parses every chunk, in order.
    @Test func noWatcherParsesEveryChunkInOrder() async {
        let chunks = ChunkLog()
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.terminal-feed-nil") { _, data in
            chunks.append(data)
        }
        defer { lane.close {} }
        lane.processOutput(Data("first".utf8))
        lane.processOutput(Data("second".utf8))
        await lane.drained()

        #expect(chunks.all == [Data("first".utf8), Data("second".utf8)])
    }
}

/// The chunks a lane's parse saw, in order.
nonisolated final class ChunkLog: Sendable {  // appended to on the output lane
    private let chunks = Mutex<[Data]>([])
    var all: [Data] { chunks.withLock { $0 } }
    func append(_ chunk: Data) { chunks.withLock { $0.append(chunk) } }
}

/// A HangWatchScoping that records every lane and scope; the lane is serial, so one stack.
final class FeedHangWatch: HangWatchScoping {
    struct Scope: Equatable, Sendable {
        var name: String
        var deadline: Duration
    }

    private struct State {
        var lanes: [String] = []
        var open: [Scope] = []
        var entered: [Scope] = []
    }

    private let state = Mutex(State())

    var lanes: [String] { state.withLock { $0.lanes } }
    var open: [Scope] { state.withLock { $0.open } }
    var entered: [Scope] { state.withLock { $0.entered } }

    func registerLane(_ name: StaticString) -> HangWatch.Registration {
        state.withLock { state in
            state.lanes.append(name.description)
            return HangWatch.Registration(slot: UInt32(state.lanes.count - 1), generation: 1)
        }
    }

    func unregister(_ registration: HangWatch.Registration) {}

    func watch<T>(_ registration: HangWatch.Registration, deadline: Duration, _ body: () throws -> T) rethrows -> T {
        state.withLock { state in
            let scope = Scope(name: state.lanes[Int(registration.slot)], deadline: deadline)
            state.open.append(scope)
            state.entered.append(scope)
        }
        defer { state.withLock { state in _ = state.open.removeLast() } }
        return try body()
    }
}
