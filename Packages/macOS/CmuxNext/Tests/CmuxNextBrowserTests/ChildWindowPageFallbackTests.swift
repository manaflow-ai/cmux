import AppKit
@testable import CmuxNextBrowser
import Testing

/// The child-window page path lives in one file (p03-rendering-053): every other file asks the
/// window's pages to update through `NSWindow.updateBrowserPageGeometry(force:)` and listens through
/// `ChildWindowPageFallback.observePageUpdates`. These pin that seam on a private center.
@MainActor
@Suite struct ChildWindowPageFallbackTests {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aRequestReachesTheObserverOfItsWindowWithItsForceFlag() {
        let center = NotificationCenter()
        let window = makeWindow(), other = makeWindow()
        defer { window.close(); other.close() }
        var seen: [Bool] = []
        let observation = ChildWindowPageFallback.observePageUpdates(of: window, center: center) { update in
            #expect(update.window === window)
            seen.append(update.force)
        }
        window.updateBrowserPageGeometry(center: center)
        window.updateBrowserPageGeometry(force: true, center: center)
        other.updateBrowserPageGeometry(force: true, center: center)
        #expect(seen == [false, true], "another window's request does not reach this window's pages")
        observation.cancel()
        window.updateBrowserPageGeometry(center: center)
        #expect(seen.count == 2, "a cancelled observation hears nothing")
    }

    @Test func anObserverOfEveryWindowGetsTheRequestingWindow() {
        let center = NotificationCenter()
        let window = makeWindow()
        defer { window.close() }
        var windows: [NSWindow?] = []
        let observation = ChildWindowPageFallback.observePageUpdates(of: nil, center: center) { windows.append($0.window) }
        window.updateBrowserPageGeometry(center: center)
        #expect(windows.count == 1 && windows.first.flatMap { $0 } === window)
        _ = observation
    }

    @Test func aHostViewSkipsARequestWhenNothingItReadsChanged() {
        let window = makeWindow()
        defer { window.close() }
        let host = CEFHostView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(host)
        defer { host.removeFromSuperview() }
        _ = host.cmuxOcclusionRects()
        _ = host.cmuxClipPath()
        let posts = CEFHostView.trackerStats.geometryPosts
        window.updateBrowserPageGeometry()
        #expect(CEFHostView.trackerStats.geometryPosts == posts, "unchanged geometry sends the fork nothing")
        window.updateBrowserPageGeometry(force: true)
        #expect(CEFHostView.trackerStats.geometryPosts == posts + 1, "a forced request re-places the page")
    }
}
