import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// Review of #33009: the status label, Restart and Retry, the find bar and the scroller are built the first
/// time they show, and a held frame (an evicted terminal's last frame, shown over its new surface until the
/// replay draws, with no time limit) sits directly above the surface. A view built later must still go over
/// the held frame: a relaunch whose attach fails says so over the last screen (TerminalFrameHold's contract).
@Suite(.serialized, .closesItsWindows)
@MainActor struct TerminalChromeOverHeldFrameTests {
    static func drawn(_ session: TerminalSession) async throws {
        let by = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < by {
            if session.surfaceView.presentedFrame != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the terminal never presented a frame")
    }

    @Test func viewsBuiltDuringAHoldShowOverTheHeldFrame() async throws {
        _ = NSApplication.shared
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let io = ScriptedTerminalIO()
        let freshIO = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            freshIO.finish()
            window.close()
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        window.contentView = root
        session.view.frame = root.bounds
        root.addSubview(session.view)
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        io.send(.output(Data("you@mac ~ % ".utf8)))
        try await Self.drawn(session)

        // Evicted, then shown again: the new session holds the last frame over its empty surface.
        session.isRenderingSuspended = true
        var frames = TerminalLastFrames()
        frames.evict(session, key: "tab", capacity: 8, atOnce: false)
        session.view.removeFromSuperview()
        session.close()
        let fresh = TerminalSession(io: freshIO)
        defer { fresh.close() }
        fresh.view.frame = root.bounds
        root.addSubview(fresh.view)
        fresh.view.layoutSubtreeIfNeeded()
        frames.show("tab", on: fresh)
        try #require(fresh.showsHeldFrame, "the setup must hold a last frame")

        let host = fresh.view
        func index(_ view: NSView?) -> Int? { view.flatMap { view in host.subviews.firstIndex { $0 === view } } }
        let held = try #require(host.subviews.firstIndex { String(describing: type(of: $0)).contains("HeldFrame") })
        #expect(index(fresh.surfaceView) == held - 1, "the held frame is directly above the surface")

        // The attach kept failing: the label and Retry are built now, during the hold.
        host.showStatus(.disconnected(.attachFailed, reconnecting: false))
        let label = try #require(host.subviews.first { $0 is TerminalStatusBanner })
        let retry = try #require(host.subviews.first { $0 is TerminalRetryButton })
        #expect(try #require(index(label)) > held, "the status label shows over the held frame")
        #expect(try #require(index(retry)) > held, "Retry shows over the held frame")
        #expect(try #require(index(retry)) > index(label) ?? 0, "Retry is over the label")

        // A scroll back during the hold builds the scroller over the held frame, under the label.
        host.showScrollbar(TerminalScrollbar(totalRows: 900, offsetRows: 876, visibleRows: 24))
        host.showScrollbar(TerminalScrollbar(totalRows: 900, offsetRows: 400, visibleRows: 24))
        let scroller = try #require(host.subviews.first { $0 is NSScrollView })
        #expect(try #require(index(scroller)) > held, "the scroller shows over the held frame")
        #expect(try #require(index(scroller)) < index(label) ?? 0, "the label is over the scroller")
    }
}
