import AppKit
@testable import CmuxNextTerminal
import Dispatch
import Foundation
import Testing

/// Terminal output reaches the Ghostty surface without the main actor (ghostty-integration-DESIGN.md
/// G4): a busy terminal must cost the main thread nothing per chunk, and an echo must not wait behind
/// a motion frame or other terminals' output on main. The surface runs in
/// `GHOSTTY_SURFACE_IO_MANUAL` (its IO does not answer queries), so Ghostty parses a device
/// attributes query on the output lane and writes its reply back to the IO; the reply arriving while
/// the main thread is blocked proves the output was parsed without it.
@MainActor @Suite(.serialized) struct TerminalOutputOffMainTests {
    @Test func outputIsParsedWhileTheMainThreadIsBusy() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = SignalingTerminalIO()
        let session = TerminalSession(io: io)
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

        // The surface's first content takes the main actor (it ends the frame hold); its query's
        // reply says it was parsed.
        io.send(.output(Data("ready\r\n\u{1b}[c".utf8)))
        let first = await Task.detached { io.waitForWrite(timeout: .seconds(10)) }.value
        try #require(first, "the first output was never parsed")
        #expect(session.surfaceHasContent)

        // Later output while the main thread is blocked: parsed and answered all the same.
        io.send(.output(Data("\u{1b}[c".utf8)))
        let answered = io.waitForWrite(timeout: .seconds(5)) // blocks the main thread
        #expect(answered, "live output waited for the main actor")
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
