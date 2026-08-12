import AppKit
import Testing
import WebKit

@testable import CmuxSidebar

@Suite("CustomSidebarInputWebView pointer focus")
@MainActor
struct CustomSidebarInputWebViewTests {
    @Test("a pointer interaction transfers native keyboard ownership before WebKit handles the click")
    func pointerInteractionClaimsKeyboardFocus() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let previousResponder = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        let webView = CustomSidebarInputWebView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(previousResponder)
        window.contentView?.addSubview(webView)
        #expect(window.makeFirstResponder(previousResponder))
        let previousFirstResponder = try #require(window.firstResponder)
        #expect(previousFirstResponder !== webView)

        var sequence: [String] = []
        webView.onRequestInputFocus = { focusedWindow in
            #expect(focusedWindow === window)
            #expect(window.firstResponder === previousFirstResponder)
            sequence.append("host")
        }

        webView.performPointerFocusHandoff {
            #expect(window.firstResponder === webView)
            sequence.append("webkit")
        }

        #expect(sequence == ["host", "webkit"])
        #expect(window.firstResponder === webView)
    }
}
