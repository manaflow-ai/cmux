import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Testing

@MainActor @Suite(.serialized, .closesItsWindows)
struct BrowserPinchPolicyTests {
    @Test func pinchOnlyReachesBrowserContent() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = content
        let browser = WebKitWebView(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        content.addSubview(browser)
        #expect(window.cmuxAllowsPinchZoom(at: NSPoint(x: 300, y: 100)))
        #expect(!window.cmuxAllowsPinchZoom(at: NSPoint(x: 100, y: 100)))
    }
}
