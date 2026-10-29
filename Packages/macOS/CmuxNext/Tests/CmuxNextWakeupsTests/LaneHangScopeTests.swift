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
    /// One ``HangWatch`` registration per slot of each lane, under the lane's name, made when the work is built:
    /// each slot is one serial queue, as Chrome watches each pool worker thread on its own.
    @Test func eachSlotRegistersOnceUnderItsLanesName() {
        let hangs = RecordingHangWatch()
        _ = BackgroundWork(cpuWidth: 3, label: "test.hang-scope-lanes", hangs: hangs)
        let files = WorkPriority.allCases.map(FilesLaneWidths.standard.width).reduce(0, +)
        #expect(hangs.lanes == Array(repeating: "lane.files", count: files)
            + Array(repeating: "lane.system", count: BackgroundWork.systemWidth) + Array(repeating: "lane.cpu", count: 3)
            + Array(repeating: "lane.bulk-files", count: BackgroundWork.bulkFilesWidth))
    }

    /// Two items of one lane that run at once open their scopes on two registrations. On one, the scope that
    /// closes first would put back the other's deadline or none (a scope restores the deadline it found), so a
    /// real hang of the other would go unreported.
    @Test func itemsThatRunAtOnceAreWatchedOnTheirOwnRegistrations() async {
        let hangs = RecordingHangWatch()
        let work = BackgroundWork(label: "test.hang-scope-overlap", hangs: hangs)
        let (started, start) = AsyncStream.makeStream(of: Void.self)
        let gate = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            work.post(.userBlocking, mayBlock: .files) {
                start.yield()
                gate.wait()
            }
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        let slots = hangs.enteredSlots
        gate.signal()
        gate.signal()
        #expect(slots.count == 2)
        #expect(Set(slots).count == 2, "both items ran on registration \(slots)")
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
        let work = BackgroundWork(filesWidths: .serial, label: "test.hang-scope-queued", hangs: hangs,
                                  onQueued: { _, _ in queue.yield() })
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

/// A HangWatchScoping that records every lane and scope; `open` is one stack, so tests that read it run one item at
/// a time.
final class RecordingHangWatch: HangWatchScoping {
    struct Scope: Equatable, Sendable {
        var name: String
        var deadline: Duration
    }

    private struct State {
        var lanes: [String] = []
        var open: [Scope] = []
        var entered: [Scope] = []
        /// The registration slot of each scope, as it opened.
        var enteredSlots: [UInt32] = []
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
    var enteredSlots: [UInt32] { state.withLock { $0.enteredSlots } }

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
            state.enteredSlots.append(registration.slot)
        }
        defer { leaving.yield(state.withLock { $0.open.removeLast() }) }
        return try body()
    }
}
