import AppKit
@testable import CmuxNextTerminal
import Testing

/// Every new terminal view built its scroller (an NSScrollView with a document, a clip-view
/// observer and a style observer): 31 of the 35 ms of TerminalHostView.init samples in the HEAVY
/// switch trace (STATUS 8158, 5.2 ms per switch). The scroller is overlay and hidden at rest, so a
/// terminal nobody scrolls back in never needs it.
@MainActor @Suite struct TerminalScrollerLazyTests {
    static func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { sub in (sub as? NSScrollView).map { [$0] } ?? scrollViews(in: sub) }
    }

    @Test func aNewTerminalBuildsNoScroller() {
        let host = TerminalHostView()
        #expect(Self.scrollViews(in: host).isEmpty, "a new terminal has no scroller view")
    }

    /// Output that follows the bottom builds none; the first move through the scrollback builds it
    /// once, and it then follows every change.
    @Test func theFirstScrollBackBuildsTheScroller() {
        let host = TerminalHostView()
        host.showScrollbar(TerminalScrollbar(totalRows: 24, offsetRows: 0, visibleRows: 24))
        host.showScrollbar(TerminalScrollbar(totalRows: 500, offsetRows: 476, visibleRows: 24))
        host.showScrollbar(TerminalScrollbar(totalRows: 900, offsetRows: 876, visibleRows: 24))
        #expect(!host.hasScroller, "output that follows the bottom is no scroll")
        host.showScrollbar(TerminalScrollbar(totalRows: 900, offsetRows: 400, visibleRows: 24))
        #expect(host.hasScroller)
        #expect(Self.scrollViews(in: host).count == 1)
        host.showScrollbar(TerminalScrollbar(totalRows: 900, offsetRows: 876, visibleRows: 24))
        host.showScrollbar(TerminalScrollbar(totalRows: 900, offsetRows: 100, visibleRows: 24))
        #expect(Self.scrollViews(in: host).count == 1, "built once")
    }
}
