import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import GhosttyNextKit
import Testing

/// ghostty-integration-DESIGN.md G7: a focused terminal at rest whose cursor is hidden (agent TUIs keep
/// DECTCEM off) changes no pixel on a cursor blink tick, so Ghostty must draw no frame for it. Each tick
/// used to update and draw a frame (about 1.7 a second per terminal).
@MainActor @Suite(.serialized) struct TerminalIdleCursorFrameTests {
    @Test func aFocusedTerminalWithAHiddenCursorDrawsNothingAtRest() async throws {
        _ = NSApplication.shared
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        let surface = try #require(session.surfaceView.surface, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            window.close()
        }
        window.contentView = session.view
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        // The runner's window is not key: focus the surface the way a key window's first responder is.
        ghostty_surface_set_focus(surface, true)
        io.send(.output(Data("ready\r\n\u{1b}[?25l".utf8)))
        let drawnBy = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < drawnBy, session.surfaceView.presentedFrame == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(session.surfaceView.presentedFrame != nil, "the terminal never drew")
        try await Task.sleep(for: .milliseconds(500)) // test: the output's own frames land

        let before = ghostty_surface_render_counters(surface)
        try await Task.sleep(for: .seconds(3)) // test: the measured rest, five blink ticks
        let after = ghostty_surface_render_counters(surface)
        let frames = after.frames - before.frames
        let updates = after.frame_updates - before.frame_updates
        #expect(frames == 0 && updates == 0, "at rest with a hidden cursor: \(frames) frames, \(updates) frame updates in 3 s")
    }
}
