#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The S7 live-resize probe's `liveResize.page_window_err_pt` (FRAME OWNER REFACTOR S7): a shown page host measures
/// against the page window nearest it. A page window with no shown host (the New Tab spare page, parked offscreen and
/// shown, under a hidden host) is no page of the window's panes and counts nothing; measured against the nearest shown
/// host it read 905 pt in every ab-s7pm2-24 film.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct ContentEdgeParkedPageTests {
    /// Named as the app's view: the probe finds page hosts by class name.
    final class CEFHostView: NSView {}

    private static func pageWindow(_ rect: NSRect) -> NSWindow {
        let page = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        page.orderFrontRegardless()
        return page
    }

    @Test func aParkedPageWindowWithNoShownHostCountsNothing() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root
        let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        root.addSubview(host)
        // The parked page's host sits in a hidden parking view.
        let parking = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        parking.isHidden = true
        parking.addSubview(CEFHostView(frame: parking.bounds))
        root.addSubview(parking)
        window.orderFrontRegardless()
        let page = Self.pageWindow(window.convertToScreen(host.convert(host.bounds, to: nil)))
        let parked = Self.pageWindow(NSRect(x: -12_000, y: -12_000, width: 400, height: 300))
        defer { [page, parked].forEach { $0.close() } }
        window.addChildWindow(page, ordered: .above)
        window.addChildWindow(parked, ordered: .above)
        try #require(page.isVisible && parked.isVisible, "SETUP: the page windows are not shown")

        let reading = try #require(ContentEdgeProbe().measure(in: window), "the probe found no pane content")
        #expect(reading.views == 1, "only the shown host: \(reading)")
        #expect(reading.pageWindow <= 1, "the shown host against its page window, not the parked one: \(reading.pageWindow) pt")
    }
}
#endif
