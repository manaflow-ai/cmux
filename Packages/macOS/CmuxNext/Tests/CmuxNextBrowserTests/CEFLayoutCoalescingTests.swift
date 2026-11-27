import AppKit
@testable import CmuxNextBrowser
import Testing

/// `CEFTabContentView` receives both resize callbacks for one AppKit pane resize. The resize callback
/// already updates every Chromium child, so the paired `layout()` must not repeat that work.
@MainActor @Suite struct CEFLayoutCoalescingTests {
    @Test func skipsOnlyTheLayoutPairedWithResizeSubviews() {
        let content = CEFTabContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))

        content.resizeSubviews(withOldSize: .zero)
        #expect(content.layoutContentInvocationCount == 1)

        content.layout()
        #expect(content.layoutContentInvocationCount == 1)

        content.layout()
        #expect(content.layoutContentInvocationCount == 2)
    }
}
