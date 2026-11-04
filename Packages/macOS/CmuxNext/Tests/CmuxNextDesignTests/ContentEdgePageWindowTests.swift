#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The S7 live-resize probe's `liveResize.page_window_err_pt` (FRAME OWNER REFACTOR S7): a page window measures against
/// the page host it sits over, never against a terminal beside it. The fork rounds a page window out to whole points, so
/// over a host at a half-point edge it overlaps the terminal next to it by that half point; measured against that
/// terminal it read hundreds of points (600-1300 pt in the ab-s7edge films).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct ContentEdgePageWindowTests {
    /// Named as the app's views: the probe finds pane contents and page hosts by class name.
    final class CEFHostView: NSView {}
    final class TerminalSurfaceView: NSView {}

    @Test func aPageWindowMeasuresAgainstItsHostNotTheTerminalBesideIt() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root
        let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 200.5, height: 300))
        root.addSubview(host)
        root.addSubview(TerminalSurfaceView(frame: NSRect(x: 200.5, y: 0, width: 199.5, height: 300)))
        window.orderFrontRegardless()
        let hostOnScreen = window.convertToScreen(host.convert(host.bounds, to: nil))
        // The fork's page window over the host: its rect rounded out to whole points (0.5 pt over the terminal).
        let page = NSWindow(contentRect: NSRect(x: hostOnScreen.minX, y: hostOnScreen.minY, width: hostOnScreen.width.rounded(.up),
                                                height: hostOnScreen.height), styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        defer { page.close() }
        page.orderFrontRegardless()
        window.addChildWindow(page, ordered: .above)
        try #require(page.isVisible && page.frame.width == 201, "SETUP: the page window is not shown at the host: \(page.frame)")

        let reading = try #require(ContentEdgeProbe().measure(in: window), "the probe found no pane content")
        #expect(reading.views == 2, "the host and the terminal: \(reading)")
        #expect(reading.pageWindow <= 1, "the page window against its host, not the terminal it overlaps: \(reading.pageWindow) pt")
    }
}
#endif
