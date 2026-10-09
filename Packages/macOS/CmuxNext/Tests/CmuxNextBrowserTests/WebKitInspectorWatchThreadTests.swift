import AppKit
import Testing
import WebKit
@testable import CmuxNextBrowser

/// The inspector watch hears every window's close notice (`object: nil`),
/// so also notices posted off the main thread. Its main-actor observer
/// trapped there (CI, BrowserPopupPanelThreadTests: SIGTRAP in
/// `WebKitInspectorWatch.windowWillClose`); it now reads on main instead
/// (crash-elimination.md, P1b).
@MainActor
@Suite struct WebKitInspectorWatchThreadTests {
    @Test func aCloseNoticePostedOffMainReadsOnMain() async {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let container = WebKitPageContainer(page: webView)
        let watch = WebKitInspectorWatch()
        watch.attach(webView: webView, container: container)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
                DispatchQueue.main.async { done.resume() }
            }
        }
        #expect(!watch.isVisible, "no inspector: the read on main finds none")
        withExtendedLifetime((container, window)) {}
    }
}
