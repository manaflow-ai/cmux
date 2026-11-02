import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// SWITCH FRAMES SF-2 (video sw-trace3-120x1/sw-w1-light.mov, feat 0d19fe6 + recorder: 25 of 26 Cmd-digit switches
/// showed EMPTY terminal panes for 1-3 refreshes). The trace build showed every revealed pane was a NEW surface:
/// the warm set (8 hidden terminals on a 16 GB Mac) had evicted it, and its last frame was not kept because its
/// screen had a single line of text (`showsOutput` false, a hover-card rule), so the reveal had no picture and the
/// fresh surface drew an empty grid before the replay. A terminal shown again after an eviction shows its last
/// frame from the reveal, whatever its screen holds; the hover card still shows no picture of an empty prompt.
@Suite(.serialized, .closesItsWindows)
@MainActor struct EvictedTerminalRevealFrameTests {
    static func drawn(_ session: TerminalSession, after previous: AnyObject? = nil) async throws {
        let by = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < by {
            if let frame = session.surfaceView.presentedFrame, frame !== previous { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the terminal never presented a frame")
    }

    @Test(arguments: ["you@mac ~ % ", "\u{1b}[?1049h\u{1b}[?25l\u{1b}[2J\u{1b}[5;1HWS 3  PANE 1  frame 1234"])
    func anEvictedTerminalWithOneLineShowsItsLastFrameWhenShownAgain(_ screen: String) async throws {
        _ = NSApplication.shared
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let freshIO = ScriptedTerminalIO()
        defer {
            io.finish()
            freshIO.finish()
            window.close()
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        window.contentView = host
        session.view.frame = host.bounds
        host.addSubview(session.view)
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        io.send(.output(Data(screen.utf8)))
        try await Self.drawn(session)
        try #require(!session.showsOutput, "the regression setup must be a one-line screen (no output for the hover card)")

        // Hidden by a switch, then evicted by the warm set (TabContentCache.evict).
        session.isRenderingSuspended = true
        var frames = TerminalLastFrames()
        frames.evict(session, key: "tab", capacity: 8, atOnce: false)
        session.view.removeFromSuperview()
        session.close()
        #expect(frames["tab"] != nil, "the warm set kept no last frame of an evicted one-line terminal: \(frames.report)")
        // The hover card rule stands: a one-line screen's kept frame is not pictured (Leo 2026-10-13).
        #expect(frames.preview("tab") == nil, "the kept frame of a one-line screen must not be a hover picture")

        // Shown again: a new session in the pane shows the last frame until its replay draws.
        let fresh = TerminalSession(io: freshIO)
        fresh.view.frame = host.bounds
        host.addSubview(fresh.view)
        fresh.view.layoutSubtreeIfNeeded()
        frames.show("tab", on: fresh)
        #expect(fresh.diagnostics.lastFrameHolds == 1, "the revealed terminal showed no last frame: an empty pane in the switch frame (\(frames.report))")
    }
}
