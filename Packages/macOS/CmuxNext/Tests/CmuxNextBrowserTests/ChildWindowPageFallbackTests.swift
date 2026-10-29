import AppKit
@testable import CmuxNextBrowser
import Testing

/// The window's page update request (`ChildPageGeometryRegistry`) and what the fork's page tracker reads
/// from a host view (`ChildWindowPageFallback`). Each test makes its own windows, and a
/// request reaches only its window's registry, so no other test's pages hear it.
@MainActor
@Suite struct ChildWindowPageFallbackTests {
    /// A window with native overlays that take the mouse over its content (dividers, the switcher).
    final class OverlayWindow: NSWindow, BrowserWindowOcclusionProviding {
        var browserOcclusionRectsInWindow: [CGRect] = []
    }

    private func makeWindow() -> OverlayWindow {
        _ = NSApplication.shared
        let window = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless,
                                   backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aRequestReachesThePagesOfItsWindowWithItsForceFlag() {
        let window = makeWindow(), other = makeWindow()
        defer { window.close(); other.close() }
        var seen: [Bool] = []
        var registration: ChildPageGeometryRegistry.Registration? = ChildPageGeometryRegistry.of(window).register { force in
            seen.append(force)
            return force
        }
        #expect(window.updateBrowserPageGeometry() == 0, "the page reported no change")
        #expect(window.updateBrowserPageGeometry(force: true) == 1)
        other.updateBrowserPageGeometry(force: true)
        #expect(seen == [false, true], "another window's request does not reach this window's pages")
        withExtendedLifetime(registration) {}
        registration = nil
        window.updateBrowserPageGeometry()
        #expect(seen.count == 2, "a released registration hears nothing")
        #expect(ChildPageGeometryRegistry.of(window).count == 0)
    }

    /// A window no page ever registered in gets no registry from a request.
    @Test func aRequestToAWindowWithNoPagesDoesNothing() {
        let window = makeWindow()
        defer { window.close() }
        #expect(window.updateBrowserPageGeometry(force: true) == 0)
        #expect(ChildPageGeometryRegistry.existing(for: window) == nil)
    }

    /// The fork gets the chrome's holes and the window's overlays over the page, in the host's
    /// coordinates and inside its bounds; a hole inside another goes, or an even-odd mask would show
    /// the page there again.
    @Test func occlusionRectsConvertTheWindowsOverlaysIntoTheHostAndKeepTheOutermost() throws {
        let window = makeWindow()
        defer { window.close() }
        let host = CEFHostView(frame: CGRect(x: 20, y: 10, width: 200, height: 100))
        let content = try #require(window.contentView)
        content.addSubview(host)
        defer { host.removeFromSuperview() }
        host.occlusionRects = [CGRect(x: 0, y: 0, width: 50, height: 50)]
        window.browserOcclusionRectsInWindow = [
            CGRect(x: 30, y: 20, width: 10, height: 10), // inside the chrome's hole: dropped
            CGRect(x: 210, y: 10, width: 100, height: 50), // past the host's right edge: cut to it
            CGRect(x: 250, y: 150, width: 20, height: 20), // off the host: dropped
        ]
        let rects = (host.cmuxOcclusionRects() as? [NSValue])?.map(\.rectValue)
        #expect(rects == [CGRect(x: 0, y: 0, width: 50, height: 50), CGRect(x: 190, y: 0, width: 10, height: 50)])
    }

    /// A page its ancestors clip away entirely is hidden by one hole over all of it, the fork's way
    /// to keep a page from showing; the clip path the fork gets is nil then.
    @Test func aHostClippedToNothingIsOneHoleOverItsBounds() throws {
        let window = makeWindow()
        defer { window.close() }
        let clip = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        let host = CEFHostView(frame: CGRect(x: 150, y: 0, width: 80, height: 60))
        try #require(window.contentView).addSubview(clip)
        clip.addSubview(host)
        defer { clip.removeFromSuperview() }
        window.browserOcclusionRectsInWindow = [CGRect(x: 0, y: 0, width: 300, height: 10)]
        let rects = (host.cmuxOcclusionRects() as? [NSValue])?.map(\.rectValue)
        #expect(rects == [host.bounds])
        #expect(host.cmuxClipPath() == nil)
    }

    /// A geometry whose view went away reads nothing and tells the fork nothing.
    @Test func aGeometryWithNoViewReadsAndPostsNothing() {
        let geometry = ChildWindowPageGeometry()
        let posts = CEFHostView.trackerStats.geometryPosts
        geometry.pagesNeedUpdate(force: true)
        geometry.forkDidReadOcclusion()
        geometry.windowDidChange()
        #expect(CEFHostView.trackerStats.geometryPosts == posts)
        #expect(geometry.occlusionRects().isEmpty)
        #expect(geometry.clipShape().path == nil)
    }
}
