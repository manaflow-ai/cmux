import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import GhosttyNextKit
import Testing

/// ghostty-integration-DESIGN.md G7: a focused terminal at rest draws no frame that changes no pixel.
/// A blink tick of a hidden cursor (agent TUIs keep DECTCEM off) used to update and draw a frame
/// (about 1.7 a second per terminal); any renderer wake (output that sets only a title, as agent
/// TUIs do several times a second) used to rebuild and draw one too.
@MainActor @Suite(.serialized) struct TerminalIdleCursorFrameTests {
    @Test func aFocusedTerminalWithAHiddenCursorDrawsNothingAtRest() async throws {
        let terminal = try await FocusedTerminal.ready()
        defer { terminal.close() }
        let surface = terminal.surface

        // Control: a visible blinking cursor redraws on blink ticks, so the ticks run in this setup.
        let start = ghostty_surface_render_counters(surface)
        try await Task.sleep(for: .seconds(2)) // test: the control window, three blink ticks
        let shown = ghostty_surface_render_counters(surface).frame_updates - start.frame_updates
        try #require(shown > 0, "no blink tick updated a visible cursor's frame: the setup does not run blink ticks")

        terminal.io.send(.output(Data("\u{1b}[?25l".utf8)))
        try await Task.sleep(for: .milliseconds(700)) // test: the hide lands and its frame draws
        let before = ghostty_surface_render_counters(surface)
        try await Task.sleep(for: .seconds(3)) // test: the measured rest, five blink ticks
        let after = ghostty_surface_render_counters(surface)
        let frames = after.frames - before.frames
        let updates = after.frame_updates - before.frame_updates
        #expect(updates == 0, "at rest with a hidden cursor: \(updates) frame updates (\(frames) frames) in 3 s; visible: \(shown) in 2 s")
    }

    /// A steady focused cursor draws 0 frames in 10 s while output that changes no cell (a title,
    /// OSC 2) wakes the renderer every 250 ms. Red at ghostty-next 723c4ab: each wake drew a frame.
    @Test func aSteadyFocusedCursorDrawsNoFrameForOutputThatChangesNothing() async throws {
        let terminal = try await FocusedTerminal.ready()
        defer { terminal.close() }
        let surface = terminal.surface

        terminal.io.send(.output(Data("\u{1b}[2 q".utf8))) // steady block
        try await Task.sleep(for: .milliseconds(700)) // test: the style lands and its frame draws
        let before = ghostty_surface_render_counters(surface)
        for tick in 0..<40 {
            terminal.io.send(.output(Data("\u{1b}]2;agent \(tick % 4)\u{07}".utf8)))
            try await Task.sleep(for: .milliseconds(250)) // test: one title wake per quarter second, 10 s
        }
        let after = ghostty_surface_render_counters(surface)
        let frames = after.frames - before.frames
        let updates = after.frame_updates - before.frame_updates
        try #require(updates > 0, "no title output woke the renderer: the setup does not reach it")
        #expect(frames == 0, "a steady focused cursor drew \(frames) frames in 10 s for \(updates) frame updates that changed nothing")
    }
}

/// A terminal in an on-screen window that has drawn its first frame, focused the way a key
/// window's first responder is (the runner's window is not key), its first output's frames landed.
@MainActor private struct FocusedTerminal {
    let io: ScriptedTerminalIO
    let session: TerminalSession
    let surface: ghostty_surface_t
    let window: NSWindow
    let drewWhenOccluded: Bool

    static func ready() async throws -> FocusedTerminal {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        guard let surface = session.surfaceView.surface else {
            io.finish()
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drew
            throw FocusedTerminalError.noSurface
        }
        let terminal = FocusedTerminal(io: io, session: session, surface: surface, window: window, drewWhenOccluded: drew)
        window.contentView = session.view
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        io.send(.output(Data("ready\r\n".utf8)))
        let drawnBy = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < drawnBy, session.surfaceView.presentedFrame == nil {
            try await Task.sleep(for: .milliseconds(20)) // test: wait for the first frame
        }
        guard session.surfaceView.presentedFrame != nil else {
            terminal.close()
            throw FocusedTerminalError.neverDrew
        }
        ghostty_surface_set_focus(surface, true)
        try await Task.sleep(for: .milliseconds(500)) // test: the output's own frames land
        return terminal
    }

    func close() {
        io.finish()
        window.close()
        WindowDrawPolicy.drawsWhenOccluded = drewWhenOccluded
    }
}

private enum FocusedTerminalError: Error, CustomStringConvertible {
    case noSurface
    case neverDrew

    var description: String {
        switch self {
        case .noSurface: "libghostty created no surface"
        case .neverDrew: "the terminal never drew"
        }
    }
}
