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
}
