import AppKit
import Testing
@testable import CmuxNextBrowser

/// WebKit's attached Web Inspector must have one owner of the page and
/// inspector frames. WebKit (WebInspectorUIProxyMac) puts the inspector
/// view into the page view's superview, sets the page view's frame to the
/// area left, and applies that again whenever the page view's frame
/// changes. Nothing else may move the page view while it is attached, or
/// each layout pass undoes WebKit and WebKit undoes the pass: the inspector
/// flickered in and out on every frame.
@MainActor
@Suite struct WebKitInspectorLayoutTests {
    /// Stand-in for WebKit's attach path (bottom dock, 40 %).
    final class FakeAttachedInspector {
        let page: NSView
        let inspector = NSView()
        private var observer: (any NSObjectProtocol)?

        init(page: NSView) {
            self.page = page
            page.superview?.addSubview(inspector, positioned: .below, relativeTo: page)
            page.postsFrameChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: page, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            apply()
        }

        isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        var expectedPage: CGRect {
            guard let bounds = page.superview?.bounds else { return .zero }
            let height = (bounds.height * 0.4).rounded()
            return CGRect(x: bounds.minX, y: bounds.minY + height, width: bounds.width, height: bounds.height - height)
        }

        func apply() {
            guard let bounds = page.superview?.bounds else { return }
            let height = (bounds.height * 0.4).rounded()
            inspector.frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
            if page.frame != expectedPage { page.frame = expectedPage }
        }
    }

    @Test func layoutPassesDoNotFightWebKitsAttachedInspector() {
        let tab = WebKitEngine().makeWebKitTab(BrowserTabConfiguration(profile: .default))
        defer { tab.close() }
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        chrome.layoutSubtreeIfNeeded()
        let page = tab.webView
        let fake = FakeAttachedInspector(page: page)
        var changes = 0
        let counter = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: page, queue: nil) { _ in
            MainActor.assumeIsolated { changes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(counter) }
        // Frames with no layout input: nothing may move the page or the inspector.
        for _ in 0..<5 {
            page.superview?.needsLayout = true
            chrome.needsLayout = true
            chrome.layoutSubtreeIfNeeded()
        }
        #expect(changes == 0, "the page view changed frame \(changes) times in 5 idle layout passes")
        #expect(page.frame == fake.expectedPage)
        #expect(fake.inspector.superview === page.superview)
        // A real resize is one input: WebKit re-places both, once.
        chrome.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        chrome.layoutSubtreeIfNeeded()
        #expect(page.frame == fake.expectedPage)
        let afterResize = changes
        for _ in 0..<5 {
            page.superview?.needsLayout = true
            chrome.layoutSubtreeIfNeeded()
        }
        #expect(changes == afterResize)
    }
}
