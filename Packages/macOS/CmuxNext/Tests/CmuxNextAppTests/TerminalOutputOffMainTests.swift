import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Dispatch
import Foundation
import Testing

/// Terminal output reaches the Ghostty surface without the main actor (ghostty-integration-DESIGN.md
/// G4): a busy terminal must cost the main thread nothing per chunk, and an echo must not wait behind
/// a motion frame or other terminals' output on main. The surface runs in
/// `GHOSTTY_SURFACE_IO_MANUAL` (its IO does not answer queries), so Ghostty parses a device
/// attributes query on the output lane and writes its reply back to the IO; the reply arriving while
/// the main thread is blocked proves the output was parsed without it. Grid steps, statuses and chips
/// take the same off-main path: the events loop never waits for the main actor.
@MainActor @Suite(.serialized) struct TerminalOutputOffMainTests {
    @Test func outputIsParsedWhileTheMainThreadIsBusy() async throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = SignalingTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            window.close()
        }
        window.contentView = session.view
        session.view.layoutSubtreeIfNeeded()

        // The surface's first content reaches the lane without the main actor too; its query's reply
        // says it was parsed, and the main actor's bookkeeping (the frame hold) follows on its frame.
        io.send(.output(Data("ready\r\n\u{1b}[c".utf8)))
        let first = await Task.detached { io.waitForWrite(timeout: .seconds(10)) }.value
        try #require(first, "the first output was never parsed")
        session.applyEvents()
        #expect(session.surfaceHasContent)

        // Later output while the main thread is blocked: parsed and answered all the same.
        io.send(.output(Data("\u{1b}[c".utf8)))
        let answered = io.waitForWrite(timeout: .seconds(5)) // blocks the main thread
        #expect(answered, "live output waited for the main actor")
    }

    /// With the main thread held, a busy terminal's grid steps, statuses and chips do not stop its
    /// output: the query after them is answered, the last grid is locked on the lane, and the main
    /// actor is asked for one turn for all of them, which applies the latest of each.
    @Test func gridAndStatusStepsDoNotWaitForTheMainThread() async throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = SignalingTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        defer { io.finish() }
        io.send(.output(Data("ready\r\n\u{1b}[c".utf8)))
        let first = await Task.detached { io.waitForWrite(timeout: .seconds(10)) }.value
        try #require(first, "the first output was never parsed")
        session.applyEvents()
        let turnsBefore = session.events.deliveries

        for index in 0..<200 {
            io.send(.status(index.isMultiple(of: 2) ? .restoring : .connected))
            io.send(.resize(cols: 60 + index % 2, rows: 20))
            io.send(.output(Data("line \(index)\r\n".utf8)))
        }
        io.send(.resize(cols: 72, rows: 18))
        io.send(.output(Data("\u{1b}[c".utf8)))
        let answered = io.waitForWrite(timeout: .seconds(10)) // blocks the main thread
        #expect(answered, "grid or status steps waited for the main actor")
        #expect(session.events.deliveries - turnsBefore <= 1, "a busy terminal asked for more than one main turn")

        let lane = try #require(session.surfaceView.lane)
        await lane.drained()
        #expect(lane.gridLock.locked == TerminalGridSize(columns: 72, rows: 18))
        #expect(session.surfaceView.currentGrid == TerminalGridSize(columns: 72, rows: 18))
        session.applyEvents()
        #expect(session.model.connection == .connected)
        #expect(session.events.take() == nil, "the main turn left changes behind")
    }
}

/// A scripted ``TerminalIO`` whose writes signal a waiter (one signal per write).
private nonisolated final class SignalingTerminalIO: TerminalIO {
    let events: AsyncStream<TerminalIOEvent>
    var answersTerminalQueries: Bool { false }
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation
    // Test-only: the main thread blocks on it to prove output needs no main actor.
    private let written = DispatchSemaphore(value: 0)

    init() {
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    func send(_ event: TerminalIOEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }

    func write(_ data: Data) async { written.signal() }
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}

    /// Whether a write came within `timeout` (blocks the calling thread).
    func waitForWrite(timeout: Duration) -> Bool {
        let nanos = Int(timeout.components.seconds) * 1_000_000_000 + Int(timeout.components.attoseconds / 1_000_000_000)
        return written.wait(timeout: .now() + .nanoseconds(nanos)) == .success
    }
}
