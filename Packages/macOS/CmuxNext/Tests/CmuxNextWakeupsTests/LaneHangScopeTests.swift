import CmuxNextCompat
@testable import CmuxNextTrace
import CmuxNextWakeups
import Dispatch
import Testing

/// Each BackgroundWork item runs in one hang scope with its lane's deadline (files 5 s, system 30 s,
/// cpu 10 s), and the wait for a slot is not in a scope: Chrome's `WatchHangsInScope` around
/// `TaskTracker::RunTask` (plans/cmux-next/chrome-parity/p02-threads.md, task 017). With no watcher
/// the lanes run as before: BackgroundWorkTests and LaneBlockingContextTests build theirs with none.
@Suite(.timeLimit(.minutes(1))) struct LaneHangScopeTests {
    /// One ``HangWatch`` lane per BlockingLane, registered when the work is built.
    @Test func eachLaneRegistersOnce() {
        let hangs = RecordingHangWatch()
        _ = BackgroundWork(label: "test.hang-scope-lanes", hangs: hangs)
        #expect(hangs.lanes == ["lane.files", "lane.system", "lane.cpu"])
    }

    @Test(arguments: zip([BlockingLane.files, .system, .cpu], [Int64(5), 30, 10]))
    func anItemRunsInsideItsLanesScope(lane: BlockingLane, seconds: Int64) async throws {
        let hangs = RecordingHangWatch()
        let work = BackgroundWork(label: "test.hang-scope", hangs: hangs)
        let expected = RecordingHangWatch.Scope(name: "lane.\(lane)", deadline: .seconds(seconds))

        let inside = try await work.run(.userVisible, mayBlock: lane) { () throws -> [RecordingHangWatch.Scope] in hangs.open }
        var left = hangs.left.makeAsyncIterator()

        #expect(inside == [expected])
        #expect(BackgroundWork.hangDeadline(lane) == .seconds(seconds))
        #expect(await left.next() == expected)
        #expect(hangs.open.isEmpty)
    }

    /// An item waiting for its slot has no scope: only the item that runs is watched.
    @Test func aQueuedItemIsNotWatched() async throws {
        let hangs = RecordingHangWatch()
        let (queued, queue) = AsyncStream.makeStream(of: Void.self)
        let (started, start) = AsyncStream.makeStream(of: Void.self)
        let work = BackgroundWork(label: "test.hang-scope-queued", hangs: hangs, onQueued: { _, _ in queue.yield() })
        let gate = DispatchSemaphore(value: 0)
        work.post(.userVisible, mayBlock: .files) {
            start.yield()
            gate.wait()  // a lane may block; it holds the files lane's userVisible slot
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()

        let second = Task { try await work.run(.userVisible, mayBlock: .files) { () throws -> Int in hangs.entered.count } }
        var queuedIterator = queued.makeAsyncIterator()
        _ = await queuedIterator.next()

        #expect(hangs.entered.count == 1)
        gate.signal()
        #expect(try await second.value == 2)
    }
}

/// A HangWatchScoping that records every lane and scope; one test thread at a time, so one stack.
final class RecordingHangWatch: HangWatchScoping {
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
    /// Each scope as it leaves.
    let left: AsyncStream<Scope>
    private let leaving: AsyncStream<Scope>.Continuation

    init() {
        (left, leaving) = AsyncStream.makeStream(of: Scope.self)
    }

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
        defer { leaving.yield(state.withLock { $0.open.removeLast() }) }
        return try body()
    }
}
