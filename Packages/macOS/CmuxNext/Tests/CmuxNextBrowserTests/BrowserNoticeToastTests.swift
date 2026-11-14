import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import Testing

/// The page's notice (the WebKit fallback, a crashed page, an added extension) is the shared toast view
/// (Lawrence 2026-11-13: every toast takes the style picked in the Toast Playground): it draws a
/// ``CmuxToastView`` in the picked style, with its action and close button, and follows a new pick.
@MainActor
@Suite struct BrowserNoticeToastTests {
    @Test func theNoticeDrawsTheSharedToastInThePickedStyle() throws {
        let styles = CmuxToastStyleStore(defaults: nil)
        styles.pick(.iconCard)
        let notice = BrowserNoticeView(styles: styles)
        var ran = 0
        notice.text = "Chromium could not start"
        notice.action = (title: "Retry", run: { ran += 1 })
        let toast = try #require(notice.toastView)
        #expect(toast.style == .iconCard)
        #expect(toast.toast.message == "Chromium could not start")
        #expect(toast.actionButton?.title == "Retry" || toast.actionButton?.accessibilityLabel() == "Retry")
        toast.actionButton?.performClick(nil)
        #expect(ran == 1)
        styles.pick(.compact)
        #expect(notice.toastView?.style == .compact, "a new pick restyles the notice that shows")
    }
}
