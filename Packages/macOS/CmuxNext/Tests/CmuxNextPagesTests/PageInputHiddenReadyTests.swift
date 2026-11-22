import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextTestSupport
import Testing
import WebKit

/// A letter typed between 2 New Tab keys waits for the first new tab's page, and it is typed when that page reports
/// its field ready (`PageInputReadiness.whenReady`). At the second New Tab key the pane stops showing the first new
/// tab: its view stays in the pane, in the window; the keyboard goes to the window; the view is hidden
/// (`PaneContentView.retire`). So the page must report ready while its view is hidden: the report comes from the
/// document's focus event, when the page's own script gives its field the focus.
///
/// What this row holds: a page in WebKit whose view is hidden as a pane hides it still sends its focus message,
/// turns ready, runs the work that waits for it, and takes the text into its field. Not in this row: the New Tab
/// page's own code, which decides when it gives its field the focus.
@MainActor
@Suite(.closesItsWindows)
struct PageInputHiddenReadyTests {
    final class Runs {
        var count = 0
    }

    /// When the pane stopped showing the page: before its document loaded (a page made at the first New Tab key,
    /// 60 ms before the second one), or after it (a page that was ready to show). `never` is the control: the same
    /// window and views with no hide, so a failure of the 2 other cases alone is a failure by the hide.
    enum Hidden: String, CaseIterable, Sendable {
        case beforeItsLoad, afterItsLoad, never
    }

    @Test(arguments: Hidden.allCases)
    func aPageThatItsPaneHidReportsItsFieldReadyAndTakesTheText(hidden: Hidden) async throws {
        let page = PageInputRefocusTests.Page()
        defer { page.window.closeAfterTest() }
        // As in a pane: the page's view in a view of the window's content, the window on screen, the keyboard in the page.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let pane = NSView(frame: content.bounds)
        page.window.contentView = content
        content.addSubview(pane)
        pane.addSubview(page.webView)
        page.window.orderFrontRegardless()
        page.window.makeFirstResponder(page.webView)
        // What `PaneContentView.retire` does to the view of a tab that its pane stops showing.
        let hide = {
            pane.handKeyboardToWindow()
            pane.isHidden = true
        }
        if hidden == .beforeItsLoad { hide() }
        await page.load()
        if hidden == .afterItsLoad { hide() }
        #expect(page.webView.isHiddenOrHasHiddenAncestor == (hidden != .never) && page.webView.window === page.window)
        #expect((page.window.firstResponder === page.window) == (hidden != .never), "the keyboard is in the wrong place")

        let runs = Runs()
        page.readiness.whenReady { runs.count += 1 }
        #expect(runs.count == 0 && !page.readiness.isReady, "the page said ready before a field had the focus")
        // The page's own script gives its field the focus. Its messages arrive before the script's reply.
        try await page.run("document.getElementById('a').focus();")
        #expect(page.readiness.focusEpoch > 0, "the page sent no focus message")
        #expect(page.readiness.isReady, "the page's field has the focus and the page did not report ready")
        #expect(runs.count == 1, "the work that waited for the page ran \(runs.count) times")
        #expect(await page.readiness.insert("x", expectedEpoch: page.readiness.focusEpoch), "the page refused the text")
        #expect(try await page.value("a") == "x")
    }
}
