import AppKit
@testable import CmuxNextTerminal
import Testing

/// Every new terminal view (a new tab, a split, a reopen, a workspace switch that makes its
/// terminals again) built a status label and showed it for "Restoring…" with its opacity held
/// at 0 until the label's wait ended. Each unhide makes AppKit walk the window's views for cursor
/// rects: 12.5 ms of main thread a HEAVY workspace switch on cmux23 (STATUS 8158), for a label
/// that never appears when the attach answers within its wait (the usual case).
@MainActor @Suite struct TerminalStatusBannerLazyTests {
    static func banners(in view: NSView) -> [TerminalStatusBanner] {
        view.subviews.flatMap { sub in (sub as? TerminalStatusBanner).map { [$0] } ?? banners(in: sub) }
    }

    @Test func aFirstAttachBuildsNoLabel() {
        let host = TerminalHostView()
        host.showStatus(.connected)
        #expect(Self.banners(in: host).isEmpty, "a connected terminal has no label view")
        // A restore that answers within its wait: nothing was built, nothing was shown.
        host.showStatus(.restoring)
        host.showStatus(.connected)
        #expect(Self.banners(in: host).isEmpty, "a Restoring… that clears within its wait builds no label")
        #expect(host.statusText == nil)
    }
}
