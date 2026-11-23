import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import ScreenCaptureKit
import Testing

/// David Beyer's Zoom call, 2026-11-20: sharing the cmux window showed everyone only black, while sharing the
/// whole desktop worked. A Chromium page parked 100,000 points off its window (`PageOffscreenParking`: a New Tab
/// spare, a retired chat, a page held away until it drew) kept its page window ordered in as a child of the cmux
/// window, out there. ScreenCaptureKit captures a window with its child windows, and with a child that far off it
/// gives no frame at all: Zoom, Meet and macOS showed black. A parked page now leaves the window (detached hosting,
/// fork API 30) and keeps drawing into its hosted context; it comes back as a child window when its view does.
///
/// Without Chromium: a fake fork places a real page window the way the fork's tracker does (a child window of
/// the host view's window, over the host view's rect, on each geometry post; ordered out while detached). The
/// window is captured through ScreenCaptureKit's current-process content, the per-window capture a window share
/// makes (no Screen Recording consent needed). Needs a display: run with `cmux-ci run --display`.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFParkedPageCaptureTests {
    nonisolated static let onScreen = ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"]
        .contains { ProcessInfo.processInfo.environment[$0] == "1" }

    /// The fork's tracker for one page window, as far as a window capture sees it.
    final class FakeTracker {
        let page: NSWindow
        weak var view: NSView?
        private(set) var detached = false
        private var observer: (any NSObjectProtocol)?

        init(view: NSView) {
            self.view = view
            page = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                            backing: .buffered, defer: false)
            page.isReleasedWhenClosed = false
            // The page's pixels are in the hosted context: the page window itself only takes input.
            page.isOpaque = false
            page.backgroundColor = .clear
            page.hasShadow = false
            observer = NotificationCenter.default.addObserver(forName: CEFHostView.geometryDidChange, object: view,
                                                              queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() } // main-proof: the host view posts on the main thread
            }
        }

        var fork: CEFLayerHosting.Fork {
            CEFLayerHosting.Fork(setLayerHosting: { _, enabled in enabled ? 7 : 0 }, setResizeSync: { _, _ in true },
                                 setDetachedHosting: { [self] _, on in
                                     detached = on
                                     update()
                                     return true
                                 })
        }

        /// `-update`: a detached page is headless and off screen; an attached one is a child window over its view.
        func update() {
            guard let view, let window = view.window else { return }
            if detached {
                page.parent?.removeChildWindow(page)
                page.orderOut(nil)
                return
            }
            page.setFrame(window.convertToScreen(view.convert(view.bounds, to: nil)), display: false)
            if page.parent !== window { window.addChildWindow(page, ordered: .above) }
        }

        func close() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            page.parent?.removeChildWindow(page)
            page.closeAfterTest()
        }
    }

    /// One cmux window with a Chromium page host in its content.
    struct Fixture {
        let window: NSWindow
        let host: CEFHostView
        let tracker: FakeTracker

        func close() {
            tracker.close()
            window.closeAfterTest()
        }
    }

    func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: CGRect(x: screen.minX + 120, y: screen.minY + 120, width: 640, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Parked page capture"
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 420))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 0, green: 0.8, blue: 0.2, alpha: 1).cgColor
        window.contentView = content
        let host = CEFHostView(frame: CGRect(x: 40, y: 40, width: 560, height: 340))
        // A cmux page is see-through: the window's green content shows through the host, as at rest under a page.
        host.pageSeeThrough = true
        content.addSubview(host)
        window.orderFrontRegardless()
        let tracker = FakeTracker(view: host)
        host.layerHosting.pageWindowCreated(browser: 4, fork: tracker.fork)
        // The hosting request runs at the end of this run-loop turn (`CEFLayerHosting.atEndOfTurn`): run that turn.
        CFRunLoopRunInMode(.defaultMode, 0, true)
        #expect(host.layerHosting.page != nil, "the page is hosted")
        host.postGeometryChange()
        return Fixture(window: window, host: host, tracker: tracker)
    }

    /// The window through ScreenCaptureKit, or nil when no frame came within `limit`: with a far child window the
    /// capture never ends, so it is raced with a deadline (a check timeout, not a settle) and a late one is ignored.
    @available(macOS 14.4, *)
    func capture(_ window: NSWindow, limit: Duration = .seconds(5)) async -> CGImage? {
        CATransaction.flush()
        let id = CGWindowID(window.windowNumber)
        let (frames, sink) = AsyncStream<CGImage?>.makeStream()
        Task.detached {
            guard let content = try? await SCShareableContent.currentProcess,
                  let shared = content.windows.first(where: { $0.windowID == id }) else {
                sink.yield(nil)
                return
            }
            let configuration = SCStreamConfiguration()
            configuration.width = 320
            configuration.height = 210
            configuration.showsCursor = false
            sink.yield(try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: shared),
                                                                  configuration: configuration))
        }
        let deadline = Task {
            // wakeup-allow: the bound of one capture check; cancelled when a frame came first
            try? await Task.sleep(for: limit)
            sink.yield(nil)
        }
        defer { deadline.cancel() }
        for await frame in frames { return frame }
        return nil
    }

    /// The share of the window that most of `image` shows the window's own green content (not black, not clear).
    func greenShare(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var green = 0
        for index in stride(from: 0, to: pixels.count, by: 4)
        where pixels[index + 3] > 200 && pixels[index + 1] > 150 && pixels[index] < 80 && pixels[index + 2] < 110 {
            green += 1
        }
        return Double(green) / Double(width * height)
    }

    /// Parks the host as `PageOffscreenParking` parks a page (100,000 points left of and below the window content,
    /// in the window), then tells the page's window to follow its view (`PageWebView.chromiumWindowMoved`).
    func park(_ fixture: Fixture) throws -> NSView {
        let content = try #require(fixture.window.contentView)
        let parking = NSView(frame: CGRect(x: content.bounds.minX - 100_000, y: content.bounds.minY - 100_000,
                                           width: 868, height: 679))
        parking.alphaValue = 0
        content.addSubview(parking, positioned: .below, relativeTo: nil)
        parking.addSubview(fixture.host)
        fixture.host.frame = parking.bounds
        pageWindowFollowsItsView(fixture)
        return parking
    }

    /// What `PageWebView.chromiumWindowMoved` posts: the window's pages follow their views now.
    func pageWindowFollowsItsView(_ fixture: Fixture) {
        // global-notice-allow: CEFHostView observes its window's page update on the default center and takes no center; posted on the main thread for this suite's own window
        NotificationCenter.default.post(name: .browserChildWindowPagesNeedUpdate, object: fixture.window,
                                        userInfo: [browserPagesForceUpdateKey: true])
    }

    /// Takes the host back into the window content (a pane adopts the page) and tells the page's window.
    func unpark(_ fixture: Fixture, from parking: NSView) {
        fixture.window.contentView?.addSubview(fixture.host)
        fixture.host.frame = CGRect(x: 40, y: 40, width: 560, height: 340)
        parking.removeFromSuperview()
        pageWindowFollowsItsView(fixture)
    }

    func expectOverItsView(_ fixture: Fixture) {
        #expect(fixture.tracker.page.parent === fixture.window, "the page window takes input over its view")
        #expect(fixture.tracker.page.frame == fixture.window.convertToScreen(fixture.host.convert(fixture.host.bounds, to: nil)))
    }

    /// Where the page window goes, with no capture (any host): parked far off, it is no child of the window and is
    /// not ordered in; back in the window, it is a child window over its view again.
    @Test func aPageParkedFarOffItsWindowLeavesItAndComesBackWithItsView() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        expectOverItsView(fixture)
        let parking = try park(fixture)
        #expect(fixture.tracker.page.parent == nil, "a parked page's window is no child window 100,000 points off")
        #expect(!fixture.tracker.page.isVisible, "and is ordered in nowhere")
        unpark(fixture, from: parking)
        expectOverItsView(fixture)
    }

    /// A divider drag that lands while the page is parked does not bring its window back out there; the page's
    /// view coming back does.
    @Test func aMotionThatLandsWhileThePageIsParkedLeavesItsWindowOut() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        fixture.host.layerHosting.resizeMotion(active: true)
        let parking = try park(fixture)
        fixture.host.layerHosting.resizeMotion(active: false)
        #expect(fixture.tracker.detached, "the landing attaches no parked page")
        #expect(fixture.tracker.page.parent == nil)
        unpark(fixture, from: parking)
        #expect(!fixture.tracker.detached)
        expectOverItsView(fixture)
    }

    @Test(.enabled(if: onScreen, "needs a display: ScreenCaptureKit captures a real window on screen"))
    func aWindowShareShowsTheWindowWhileAChromiumPageIsParkedFarOffIt() async throws {
        guard #available(macOS 14.4, *) else { return }
        let fixture = try fixture()
        defer { fixture.close() }
        let shown = try #require(await capture(fixture.window), "a window with its page shown in it is captured")
        #expect(greenShare(shown) > 0.5, "the capture is the window: \(greenShare(shown))")

        let parking = try park(fixture)
        let parked = await capture(fixture.window)
        #expect(parked != nil, "a window share of the window gets a frame while a page is parked far off it")
        if let parked { #expect(greenShare(parked) > 0.5, "the parked page adds no empty space: \(greenShare(parked))") }

        unpark(fixture, from: parking)
        expectOverItsView(fixture)
        let back = try #require(await capture(fixture.window), "the window is captured with its page back in it")
        #expect(greenShare(back) > 0.5, "the capture is the window: \(greenShare(back))")
    }
}
