import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
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
        defer { fresh.close() }
        frames.show("tab", on: fresh)
        #expect(fresh.diagnostics.lastFrameHolds == 1, "the revealed terminal showed no last frame: an empty pane in the switch frame (\(frames.report))")
    }

    /// Review of #32315: the store now keeps up to 152 frames, so a closed tab's frame must go with the tab, not
    /// wait for later evictions to push it out.
    @Test func aClosedTabsLastFrameGoesWithIt() async throws {
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
        defer {
            io.finish()
            window.close()
        }
        window.contentView = session.view
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        io.send(.output(Data("closed tab\r\nline\r\n".utf8)))
        try await Self.drawn(session)
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()),
                                    fileInput: NoFileInput())
        session.isRenderingSuspended = true
        cache.lastFrames.evict(session, key: "tab_closed", capacity: 8, atOnce: false)
        session.close()
        try #require(cache.lastFrames["tab_closed"] != nil, "setup: the evicted terminal kept no frame")
        cache.release("tab_closed")
        #expect(cache.lastFrames["tab_closed"] == nil, "a closed tab's last frame stayed in the store: \(cache.lastFrames.report)")
    }

    /// The real-app case (sw-sf2fix-light2, cmux24: last_frames kept +2 and dropped +2 per switch, shown 0): 18
    /// terminals in 9 workspaces cycled by Cmd-1..9 on a 16 GB Mac. A terminal evicted 8 evictions ago must still
    /// have its last frame when a switch shows it again.
    @Test func aTerminalEvictedEightEvictionsAgoStillHasItsLastFrame() async throws {
        _ = NSApplication.shared
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var ios: [ScriptedTerminalIO] = []
        defer {
            ios.forEach { $0.finish() }
            window.close()
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        window.contentView = host
        window.orderFrontRegardless()
        var frames = TerminalLastFrames()
        // The warm set of a 16 GB Mac (WarmSetBudget.forMemory: 8): 9 terminals leave it.
        let capacity = 8
        for index in 0..<9 {
            let io = ScriptedTerminalIO()
            ios.append(io)
            let session = TerminalSession(io: io)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            session.view.frame = host.bounds
            host.addSubview(session.view)
            session.view.layoutSubtreeIfNeeded()
            io.send(.output(Data("\u{1b}[2J\u{1b}[Hterminal \(index)\r\nline\r\nline\r\n".utf8)))
            try await Self.drawn(session)
            session.isRenderingSuspended = true
            frames.evict(session, key: "tab-\(index)", capacity: capacity, atOnce: false)
            session.view.removeFromSuperview()
            session.close()
        }
        #expect(frames["tab-0"] != nil, "the first evicted terminal's frame was dropped after 8 more evictions (warm capacity \(capacity)): \(frames.report)")
    }
}
