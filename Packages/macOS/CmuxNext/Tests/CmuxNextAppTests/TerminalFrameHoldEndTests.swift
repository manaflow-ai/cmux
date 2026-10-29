import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// principled-audit restoreFrameHold, part 2 (R5, R6): a held frame stays over a terminal until the content parsed at
/// its attach or swap is drawn, never ended by a timer, and the session owns it: closing the session or an exit with
/// no content ends it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalFrameHoldEndTests {
    /// A terminal in a window that is never on screen (so it never draws), held over a launch frame, with a deadline
    /// scheduler the test fires.
    @MainActor final class Rig {
        let rig: MainDeadlineRig
        let io: ScriptedTerminalIO
        let session: TerminalSession
        let window: NSWindow
        private let drawsWhenOccluded: Bool
        private let onScreen: (NSWindow) -> Bool
        /// The test closed the session itself.
        var sessionClosed = false

        init() throws {
            _ = NSApplication.shared
            GhosttyRuntime.startedForTests()
            drawsWhenOccluded = WindowDrawPolicy.drawsWhenOccluded
            onScreen = WindowDrawPolicy.onScreen
            WindowDrawPolicy.drawsWhenOccluded = false
            WindowDrawPolicy.onScreen = { _ in false }
            let rig = MainDeadlineRig(), io = ScriptedTerminalIO()
            let session = TerminalSession(io: io, mainWork: rig.work, deadlines: rig.deadlines)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            session.view.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
            window.contentView = session.view
            (self.rig, self.io, self.session, self.window) = (rig, io, session, window)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            try #require(TerminalLaunchFrame(try #require(context.makeImage())).show(on: session))
            try #require(session.frameHold.isHolding)
        }

        /// Runs the session's posted work until `done` holds (the events loop and the lane are other threads).
        func run(until done: () -> Bool) async throws {
            for _ in 0..<300 where !done() {
                rig.frame()
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func close() {
            io.finish()
            if !sessionClosed { session.close() }
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drawsWhenOccluded
            WindowDrawPolicy.onScreen = onScreen
        }
    }

    /// R5: `TerminalFrameHold.limit` (500 ms from the content's queueing) took the held frame away whether or not the
    /// surface drew: a terminal whose window is covered shows the empty surface the moment it is uncovered.
    @Test func aHoldWithQueuedContentStaysUntilTheSurfaceDrawsIt() async throws {
        let pane = try Rig()
        defer { pane.close() }
        pane.io.send(.replay(Data("restored\r\n".utf8)))
        try await pane.run { pane.session.surfaceHasContent }
        try #require(pane.session.surfaceHasContent, "the replay never reached the session")
        try #require(pane.session.surfaceView.pause != nil, "the surface of a window off screen draws")

        for _ in 0..<16 {
            pane.rig.advance(by: .seconds(1))
            if pane.rig.hasArmedWake { pane.rig.fireAndRun() } else { pane.rig.frame() }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(pane.session.frameHold.isHolding, "a timer ended the hold over a surface that never drew its content")
    }

    /// R6: `TerminalSession.close()` left the held frame (and its frame client) behind.
    @Test func closingTheSessionEndsItsHold() throws {
        let pane = try Rig()
        defer { pane.close() }

        pane.session.close()
        pane.sessionClosed = true

        #expect(!pane.session.frameHold.isHolding, "a closed session still holds its frame")
    }

    /// R6: a hold that waits for its first content had no end when none comes: the terminal exited before any output.
    @Test func anExitWithNoContentEndsTheHold() async throws {
        let pane = try Rig()
        defer { pane.close() }

        pane.io.send(.exited)
        try await pane.run { pane.session.model.hasExited && !pane.session.frameHold.isHolding }

        try #require(pane.session.model.hasExited, "the exit never reached the session")
        #expect(!pane.session.frameHold.isHolding, "the exited terminal with no content still holds its frame")
    }
}
