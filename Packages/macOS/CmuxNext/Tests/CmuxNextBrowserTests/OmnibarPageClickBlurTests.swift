import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-10-30 (msg 17829): "i click outside and omnibar is still focused" on a Chromium
/// New Tab page with "goo" typed. Chromium: a press on the page focuses the web contents and the
/// omnibox blurs (`OmniboxViewViews::OnBlur`): the caret and the selection go, the popup closes, the
/// typed text stays.
///
/// Until a Chromium tab's first real page (the New Tab page, a blank page) its page window is cut
/// out over the whole page (`CEFTab.applyOcclusion`), so the press lands on the pane's own
/// ``CEFHostView`` in the cmux window, not in Chromium's window. That view must end the edit as a
/// press in the page window does.
@MainActor @Suite(.serialized, .closesItsWindows)
struct OmnibarPageClickBlurTests {
    private func scene() -> (AddressBarView, CEFHostView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let bar = AddressBarView()
        bar.frame = NSRect(x: 10, y: 450, width: 600, height: 34)
        let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 700, height: 440))
        window.contentView!.addSubview(host)
        window.contentView!.addSubview(bar)
        bar.update(url: URL(string: BrowserNewTabPage.chromiumURL), security: .none)
        bar.layoutSubtreeIfNeeded()
        return (bar, host, window)
    }

    private func press(_ type: NSEvent.EventType, on view: NSView, in window: NSWindow) throws {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        switch type {
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .otherMouseDown: view.otherMouseDown(with: event)
        default: view.mouseDown(with: event)
        }
    }

    @Test(arguments: [NSEvent.EventType.leftMouseDown, .rightMouseDown])
    func aPressOnTheNewTabPageEndsTheEditAndKeepsTheTypedText(_ type: NSEvent.EventType) throws {
        let (bar, host, window) = scene()
        defer { window.closeAfterTest() }
        bar.debugType("goo")
        #expect(bar.isEditing)
        try press(type, on: host, in: window)
        #expect(!bar.isEditing, "the omnibar kept the keyboard after a press on the page")
        #expect(!(window.firstResponder is NSText), "a field editor is still first responder: the caret and the selection still show")
        #expect(bar.displayedText == "goo", "the typed text stays in the box, as in Chromium")
    }

    /// The press focuses the page, not nothing: the host view is the window's first responder for
    /// the focus model to classify as the pane's content (`FocusResponderClassifier`, `.page`).
    @Test func aPressOnThePageMakesThePageTheResponder() throws {
        let (bar, host, window) = scene()
        defer { window.closeAfterTest() }
        bar.debugType("goo")
        try press(.leftMouseDown, on: host, in: window)
        #expect(window.firstResponder === host)
    }

    /// The host view never joins the keyboard loop (Tab never lands on it).
    @Test func theHostViewIsNotAKeyView() {
        let (_, host, window) = scene()
        defer { window.closeAfterTest() }
        #expect(!host.canBecomeKeyView)
    }
}
