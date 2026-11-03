import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// Review of #33009: the status label, Restart and Retry, the find bar and the scroller are built the first
/// time they show, and a held frame (a terminal's frame from the last quit, shown over its new surface until
/// the replay draws, with no time limit) sits directly above the surface. A view built later must still go
/// over the held frame: a relaunch whose attach fails says so over the last screen (TerminalFrameHold's
/// contract). An evicted terminal's last frame is the surface's own contents instead (SWITCH FRAMES item 2:
/// no layer over the surface), so the same views go over the surface that shows it.
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

    /// A session in `root` with a window, and the cleanup.
    struct Setup {
        let window: NSWindow
        let root: NSView
        let ios: [ScriptedTerminalIO]
        func close() {
            ios.forEach { $0.finish() }
            window.close()
        }
    }

    static func setup(_ ios: [ScriptedTerminalIO]) -> Setup {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        window.contentView = root
        window.orderFrontRegardless()
        return Setup(window: window, root: root, ios: ios)
    }

    /// The label, Retry and the scroller, built during the hold, go over `cover` (the held frame or the surface that
    /// shows the frame), and in their own order.
    static func expectChrome(over cover: NSView, in host: TerminalHostView, _ what: String) throws {
        func index(_ view: NSView?) -> Int? { view.flatMap { view in host.subviews.firstIndex { $0 === view } } }
        let under = try #require(index(cover), "\(what) is not in the host")
        // The attach kept failing: the label and Retry are built now, during the hold.
        host.showStatus(.disconnected(.attachFailed, reconnecting: false))
        let label = try #require(host.subviews.first { $0 is TerminalStatusBanner })
        let retry = try #require(host.subviews.first { $0 is TerminalRetryButton })
        #expect(try #require(index(label)) > under, "the status label shows over \(what)")
        #expect(try #require(index(retry)) > under, "Retry shows over \(what)")
        #expect(try #require(index(retry)) > index(label) ?? 0, "Retry is over the label")
        // A scroll back during the hold builds the scroller over the frame, under the label.
        host.showScrollbar(TerminalScrollbar(totalRows: 900, offsetRows: 876, visibleRows: 24))
        host.showScrollbar(TerminalScrollbar(totalRows: 900, offsetRows: 400, visibleRows: 24))
        let scroller = try #require(host.subviews.first { $0 is NSScrollView })
        #expect(try #require(index(scroller)) > under, "the scroller shows over \(what)")
        #expect(try #require(index(scroller)) < index(label) ?? 0, "the label is over the scroller")
    }

    /// A terminal's frame from the last quit, held over its new session's empty surface (TerminalFrameHold).
    @Test func viewsBuiltDuringAHoldShowOverTheHeldFrame() async throws {
        let io = ScriptedTerminalIO()
        let setup = Self.setup([io])
        defer { setup.close() }
        let fresh = TerminalSession(io: io)
        defer { fresh.close() }
        try #require(fresh.surfaceView.surface != nil, "libghostty created no surface")
        fresh.view.frame = setup.root.bounds
        setup.root.addSubview(fresh.view)
        fresh.view.layoutSubtreeIfNeeded()
        let context = try #require(CGContext(data: nil, width: 960, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 480))
        let image = try #require(context.makeImage())
        try #require(TerminalLaunchFrame(image).show(on: fresh), "the setup must hold a launch frame")

        let host = fresh.view
        let held = try #require(host.subviews.first { String(describing: type(of: $0)).contains("HeldFrame") })
        #expect(host.subviews.firstIndex { $0 === fresh.surfaceView } == (host.subviews.firstIndex { $0 === held } ?? 0) - 1,
                "the held frame is directly above the surface")
        try Self.expectChrome(over: held, in: host, "the held frame")
    }

    /// An evicted terminal's last frame, shown again by its new session: the surface's own contents, with no layer
    /// over the surface, and the views built during the hold go over that surface.
    @Test func viewsBuiltWhileAnEvictedFrameShowsGoOverTheSurfaceThatShowsIt() async throws {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let io = ScriptedTerminalIO(), freshIO = ScriptedTerminalIO()
        let setup = Self.setup([io, freshIO])
        defer { setup.close() }
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        session.view.frame = setup.root.bounds
        setup.root.addSubview(session.view)
        session.view.layoutSubtreeIfNeeded()
        io.send(.output(Data("you@mac ~ % ".utf8)))
        try await Self.drawn(session)
        let saved = try #require(session.surfaceView.presentedFrame)

        // Evicted, then shown again.
        session.isRenderingSuspended = true
        var frames = TerminalLastFrames()
        frames.evict(session, key: "tab", capacity: 8, atOnce: false)
        session.view.removeFromSuperview()
        session.close()
        let fresh = TerminalSession(io: freshIO)
        defer { fresh.close() }
        fresh.view.frame = setup.root.bounds
        setup.root.addSubview(fresh.view)
        fresh.view.layoutSubtreeIfNeeded()
        frames.show("tab", on: fresh)
        try #require(fresh.showsHeldFrame, "the setup must show the last frame")

        let host = fresh.view
        #expect(!host.subviews.contains { String(describing: type(of: $0)).contains("HeldFrame") },
                "an evicted terminal's last frame is on a layer over its surface")
        #expect((fresh.surfaceView.layer?.contents as CFTypeRef?) === saved, "the surface does not show the evicted terminal's last frame")
        try Self.expectChrome(over: fresh.surfaceView, in: host, "the surface that shows the last frame")
    }
}
