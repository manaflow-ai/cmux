import AppKit
@testable import CmuxNextBrowser
import Testing

/// The gap beside a Chromium page's last frame while it lays out at a new size shows the host view
/// under the page window. With the app's commit no longer held for Chromium's frame at the new size
/// (AsyncLiveResize, PL-motion-cef batch 1), that gap shows on a divider drag, a split, a close and a
/// sidebar slide too, not only in a window live resize (review 1, finding 2): it takes the page's own
/// background there as well, so it reads as more page, never as a band of the pane ground.
@MainActor
@Suite struct CEFHostViewResizeGapTests {
    @Test func aKnownPageBackgroundFillsTheHostOutsideAWindowLiveResize() throws {
        let view = CEFHostView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        #expect(!view.inLiveResize)
        let page = CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        view.pageBackdrop = page
        #expect(try #require(view.layer).backgroundColor == page, "a pane resize's gap is the page's color")
        // Before the first real page there is no page color: the pane ground stays.
        view.pageBackdrop = nil
        #expect(try #require(view.layer).backgroundColor != page)
    }
}
