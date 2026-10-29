import AppKit
import CmuxNextCompat
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Darwin
import Dispatch
import Foundation
import Testing

/// A session sends its input through one ``TerminalInputLane`` drained on the IO's own queue:
/// the bytes it sends arrive in order, each handled on that queue, with no writer task
/// between the main thread and the IO.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct TerminalSessionTests {
    @Test func sentBytesReachTheIOQueueInOrder() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = LaneRecordingTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.close() }

        let sent = (0..<1_000).map { "k\($0)" }
        for text in sent { session.sendBytes(Data(text.utf8)) }

        let received = await io.waitForKeys(sent.count)
        #expect(received.map(\.text) == sent)
        #expect(received.allSatisfy { $0.onIOQueue }, "a record was handled off the IO's drain queue")
    }

    /// The session's part of the echo lane's order: it names no lane before the first content,
    /// names the surface's lane after the first replay and the swapped-in surface's after a later one, names
    /// none on close, and resumes a marker only once every event before it is on the lane. Each marker's
    /// resume sends live bytes straight to the lane named then, as the attach reader does once the route
    /// opens: they must land after the replay and output ahead of the marker, on the surface shown.
    @Test func namesItsOutputLaneAndResumesMarkersBehindAppliedEvents() async throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = LaneNamingTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            session.close()
            io.finish()
            window.close()
        }
        window.contentView = session.view
        session.view.layoutSubtreeIfNeeded()
        var resumes = io.resumes.makeAsyncIterator()

        // (1) No content yet: no lane is named, and a marker's resume finds none.
        io.send(.status(.connected))
        io.sendMarker(live: "early")
        let beforeContent = try #require(await resumes.next())
        #expect(beforeContent.named == nil)
        #expect(io.namedLanes.isEmpty, "a lane was named before the first content")

        // (2) The first replay names the surface's lane; the marker behind it and an output resumes after both
        // are on that lane, so its live bytes follow them.
        io.send(.replay(Data("first".utf8)))
        io.send(.output(Data("xyz".utf8)))
        io.sendMarker(live: "!")
        let afterReplay = try #require(await resumes.next())
        let firstLane = try #require(session.surfaceView.lane)
        #expect(io.namedLanes.count == 1)
        #expect(afterReplay.named === firstLane, "the marker resumed before the replay's lane was named")
        await firstLane.drained()
        #expect(session.surfaceView.viewportText()?.contains("firstxyz!") == true,
                "live bytes reached the lane before the replay or output ahead of their marker")

        // (3) A later replay swaps the surface in: its lane is named, and live bytes land on it after the replay.
        io.send(.replay(Data("second".utf8)))
        io.sendMarker(live: "+more")
        let afterSwap = try #require(await resumes.next())
        let secondLane = try #require(session.surfaceView.lane)
        #expect(secondLane !== firstLane, "the replay swapped no surface in")
        #expect(io.namedLanes.count == 2)
        #expect(afterSwap.named === secondLane, "the swapped-in surface's lane was not named before the marker")
        await secondLane.drained()
        #expect(session.surfaceView.viewportText()?.contains("second+more") == true)

        // (4) Close names none.
        session.close()
        #expect(io.namedLanes.count == 3)
        #expect(io.namedLanes.last.map { $0 == nil } == true, "close kept a lane named")
    }
}

/// A ``TerminalIO`` that records each lane the session names (``TerminalIO/setOutputLane(_:)``) and sends
/// markers whose resume feeds the lane named then, as the attach reader does.
private nonisolated final class LaneNamingTerminalIO: TerminalIO {
    /// One marker's resume: the lane named when it ran.
    nonisolated struct Resume: Sendable {
        var named: TerminalOutputLane?
    }

    let events: AsyncStream<TerminalIOEvent>
    let resumes: AsyncStream<Resume>
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation
    private let resumed: AsyncStream<Resume>.Continuation
    private let named = Mutex<[TerminalOutputLane?]>([])

    init() {
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
        (resumes, resumed) = AsyncStream<Resume>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Every lane named so far, nil for none.
    var namedLanes: [TerminalOutputLane?] { named.withLock { $0 } }

    func send(_ event: TerminalIOEvent) { continuation.yield(event) }

    func finish() {
        continuation.finish()
        resumed.finish()
    }

    /// A marker behind every event sent so far. Its resume sends `live` straight to the lane named then.
    func sendMarker(live: String) {
        send(.outputResume(TerminalOutputResume { [self] in
            let lane = named.withLock { $0.last ?? nil }
            _ = lane?.enqueueEcho(Data(live.utf8), flow: nil, wake: {})
            resumed.yield(Resume(named: lane))
        }))
    }

    func setOutputLane(_ lane: TerminalEchoLane?) {
        named.withLock { $0.append(lane?.lane) }
    }

    func write(_ data: Data) async {}
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
}

/// A ``TerminalIO`` whose input drain records each `k`-prefixed bytes record and whether it ran on its queue.
private nonisolated final class LaneRecordingTerminalIO: TerminalIO {
    nonisolated struct Key: Sendable {
        var text: String
        var onIOQueue: Bool
    }

    let events = AsyncStream<TerminalIOEvent> { _ in }
    // qos-allow: a test drain standing for the attach input queue, which runs at this class
    private let queue = DispatchQueue(label: "com.cmuxterm.next.test.session-input", qos: .userInteractive)
    private let state = Mutex(State())

    private nonisolated struct State {
        var keys: [Key] = []
        var waiter: (count: Int, continuation: CheckedContinuation<[Key], Never>)?
    }

    func write(_ data: Data) async {}
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}

    func inputDrain() -> TerminalInputDrain {
        TerminalInputDrain(queue: queue) { [self] record, _ in
            guard case .bytes(let data) = record else { return .next }
            let text = String(decoding: data, as: UTF8.self)
            guard text.hasPrefix("k") else { return .next }
            let key = Key(text: text, onIOQueue: String(cString: __dispatch_queue_get_label(nil)) == queue.label)
            let ready = state.withLock { state -> (CheckedContinuation<[Key], Never>, [Key])? in
                state.keys.append(key)
                guard let waiter = state.waiter, state.keys.count >= waiter.count else { return nil }
                state.waiter = nil
                return (waiter.continuation, state.keys)
            }
            if let ready { ready.0.resume(returning: ready.1) }
            return .next
        }
    }

    /// The `k` keys once `count` arrived.
    func waitForKeys(_ count: Int) async -> [Key] {
        await withCheckedContinuation { continuation in
            let keys = state.withLock { state -> [Key]? in
                guard state.keys.count < count else { return state.keys }
                state.waiter = (count, continuation)
                return nil
            }
            if let keys { continuation.resume(returning: keys) }
        }
    }
}
