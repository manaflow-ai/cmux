import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// TERMINAL CREATE COST (cmux21 Time Profiler, STATUS 11351): New Terminal Tab over a History tab spent 8 of its 19 ms
/// key turn hiding the History page. The page held the keyboard when the cache hid it, so AppKit walked the window's
/// whole key view loop for a replacement first responder (`-[NSView nextValidKeyView]`,
/// `_NSComputeFirstKeyViewVisuallyInDirection`, 5.5 ms) before the new tab's own focus took it anyway. The keyboard
/// now leaves a page before the page hides: the window takes it, and the focus model gives it to what shows now.
@MainActor @Suite(.serialized, .closesItsWindows)
struct HiddenPageKeyboardHandoffTests {
    @Test func aPageThatHidesNoLongerHoldsTheKeyboard() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let key = tab.id.rawValue
        _ = services.cache.install(tab, for: key)
        defer { services.cache.browsers[key] = nil }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        let page = tab.contentView
        page.frame = root.bounds
        root.addSubview(page)
        let field = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        page.addSubview(field)
        window.orderFrontRegardless()
        try #require(window.makeFirstResponder(field), "the page's view did not take the keyboard")
        let cache = services.cache
        cache.applyLifecycle(cache.lifecycle.send(.show(key)))
        try #require(!tab.isContentHidden, "the page never showed")

        cache.applyLifecycle(cache.lifecycle.send(.hide(key)))
        #expect(tab.isContentHidden)
        let responder = window.firstResponder as? NSView
        #expect(responder.map { !$0.isDescendant(of: page) } ?? true,
                "the hidden page still holds the keyboard: AppKit walks the key view loop when it hides")
    }
}

/// A view that takes the keyboard (as a page's web view does).
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
