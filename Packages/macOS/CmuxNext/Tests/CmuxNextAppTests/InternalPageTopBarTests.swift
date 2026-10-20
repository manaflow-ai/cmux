import AppKit
@testable import CmuxNextApp
import Testing

/// A page tab may carry a native bar above its page (the Markdown omnibar, design section 2): the
/// bar sits at the top at its own height, the page fills the rest, and `content` stays the page so
/// every `content as? PageWebView` path keeps working.
@MainActor @Suite struct InternalPageTopBarTests {
    @Test func theTopBarSitsAboveTheContent() throws {
        let content = NSView()
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let view = InternalPageView(key: "k", page: InternalPageID(rawValue: "cmux.markdown"), content: content, topBar: bar)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.layoutSubtreeIfNeeded()
        #expect(view.content === content)
        #expect(view.topBar === bar)
        #expect(bar.frame.height == 40)
        #expect(bar.frame.width == 600)
        #expect(content.frame.height == 360)
        // AppKit's y grows upward: the bar is over the content.
        #expect(bar.frame.minY >= content.frame.maxY || view.isFlipped && bar.frame.maxY <= content.frame.minY)
    }

    @Test func withoutABarTheContentFillsTheTab() {
        let content = NSView()
        let view = InternalPageView(key: "k", page: InternalPageID(rawValue: "cmux.markdown"), content: content)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.layoutSubtreeIfNeeded()
        #expect(view.topBar == nil)
        #expect(content.frame == view.bounds)
    }
}
