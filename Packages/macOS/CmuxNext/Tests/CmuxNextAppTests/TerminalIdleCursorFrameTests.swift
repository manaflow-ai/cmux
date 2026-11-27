import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import GhosttyNextKit
import Testing

/// ghostty-integration-DESIGN.md G7: a focused terminal at rest whose cursor is hidden (agent TUIs keep
/// DECTCEM off) changes no pixel on a cursor blink tick, so Ghostty must draw no frame for it. Each tick
/// used to update and draw a frame (about 1.7 a second per terminal).
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalIdleCursorFrameTests {
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
        // The runner's window is not key: the surface is focused below the way a key window's first
        // responder is.
        io.send(.output(Data("ready\r\n".utf8)))
        let drawnBy = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < drawnBy, session.surfaceView.presentedFrame == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(session.surfaceView.presentedFrame != nil, "the terminal never drew")
        ghostty_surface_set_focus(surface, true)
        try await Task.sleep(for: .milliseconds(500)) // test: the output's own frames land

        // Control: a visible blinking cursor redraws on blink ticks, so the ticks run in this setup.
        let start = ghostty_surface_render_counters(surface)
        try await Task.sleep(for: .seconds(2)) // test: the control window, three blink ticks
        let shown = ghostty_surface_render_counters(surface).frame_updates - start.frame_updates
        try #require(shown > 0, "no blink tick updated a visible cursor's frame: the setup does not run blink ticks")

        io.send(.output(Data("\u{1b}[?25l".utf8)))
        try await Task.sleep(for: .milliseconds(700)) // test: the hide lands and its frame draws
        let before = ghostty_surface_render_counters(surface)
        try await Task.sleep(for: .seconds(3)) // test: the measured rest, five blink ticks
        let after = ghostty_surface_render_counters(surface)
        let frames = after.frames - before.frames
        let updates = after.frame_updates - before.frame_updates
        #expect(updates == 0, "at rest with a hidden cursor: \(updates) frame updates (\(frames) frames) in 3 s; visible: \(shown) in 2 s")
    }
}
