import AppKit
import CmuxNextPages
import Testing
import WebKit

/// Leo, 2026-11-12: typing should feel like nothing as chats grow. WebKit drew a key's edit only at
/// the display's next refresh (the agent chat's own engine: keydown to frame p95 17 ms at 60 Hz on
/// aws-m4pro-7, Chromium 9.1). A first-party page's web view now asks WebKit to render right behind
/// each key down, once, with no timer.
@MainActor
struct RenderKeyEditNowTests {
    /// Answers WebKit's selector and counts the calls, as WKWebView would take them.
    final class CountingView: NSView {
        var updates = 0
        @objc func _doAfterNextPresentationUpdate(_ block: Any?) { updates += 1 }
    }

    @Test func oneKeyAsksForOneRenderingUpdate() {
        let view = CountingView(frame: .zero)
        view.renderKeyEditNow()
        #expect(view.updates == 1)
        view.renderKeyEditNow()
        #expect(view.updates == 2)
    }

    @Test func aViewWithoutTheSelectorIsLeftAlone() {
        // No selector, no call: an unknown selector would raise.
        NSView(frame: .zero).renderKeyEditNow()
    }

    @Test func thisWebKitHasTheSelector() {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: WKWebViewConfiguration())
        #expect(web.responds(to: NSSelectorFromString("_doAfterNextPresentationUpdate:")))
    }
}
