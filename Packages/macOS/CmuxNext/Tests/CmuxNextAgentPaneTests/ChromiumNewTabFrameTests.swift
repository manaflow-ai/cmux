#if DEBUG
import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A New Tab page in Chromium (the default engine) that has not painted drew nothing: Cmd-T with no prewarmed page to
/// adopt (a second Cmd-T before the spare refills, or the first after a launch) showed the pane's ground until the page
/// loaded and painted, many frames after the key. The parked spare in Chromium now gives the app's New Tab frame (a
/// picture that keeps the page's clear areas), and a Chromium New Tab page that has not painted lies outside the window
/// over that picture until it paints, then comes back in that turn: the picture is the page's real empty state, and the
/// page never draws over it in pieces.
@MainActor @Suite(.serialized, .closesItsWindows)
struct ChromiumNewTabFrameTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A size no other test stores a New Tab frame at (the frames are the app's, shared).
    private static let size = NSSize(width: 813, height: 611)

    /// A New Tab page in Chromium, laid out at `size` out of any window (a parked spare), shown in Chromium.
    private func chromiumNewTabPage() async throws -> (AgentPaneView, FakeChromiumHosting) {
        _ = NSApplication.shared
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), newTab: AgentPaneNewTab(kind: .agent)),
                                              source: .bundled(file), pageHost: true, testRoot: true, chromium: hosting))
        if let page = view.page { await page.chromiumStart?.value }
        view.frame = NSRect(origin: .zero, size: Self.size)
        view.layoutSubtreeIfNeeded()
        #expect(view.debugShowsChromium, "the page shows in Chromium")
        view.layoutSubtreeIfNeeded()
        return (view, hosting)
    }

    /// A PNG of `size` at 2x, clear but for one opaque square: what `Page.captureScreenshot` answers for a see-through page.
    private static func clearPNG(_ size: NSSize) throws -> String {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 10, y: 10, width: 40, height: 40).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:])).base64EncodedString()
    }

    @Test func aParkedChromiumSpareGivesTheAppsNewTabFrameAPictureWithItsClearAreas() async throws {
        let (view, hosting) = try await chromiumNewTabPage()
        let page = try #require(hosting.made.last)
        let png = try Self.clearPNG(Self.size)
        page.answer = { method, _ in method == "Page.captureScreenshot" ? #"{"data":"\#(png)"}"# : nil }
        let frames = AgentPaneNewTabFrame.shared
        frames.pageMade(view.model)
        #expect(frames.image(size: Self.size, appearance: .darkAqua) == nil)
        await withCheckedContinuation { done in view.redraw.rememberFrame(of: view, appearance: .darkAqua) { done.resume() } }
        let shots = page.calls.filter { $0.method == "Page.captureScreenshot" }
        #expect(shots.count == 1 && shots.first?.params["format"] as? String == "png",
                "a Chromium New Tab spare is pictured once, as a PNG (a JPEG draws its clear areas black): \(shots.map(\.params))")
        let image = try #require(frames.image(size: Self.size, appearance: .darkAqua),
                                 "the app's New Tab frame at the spare's size: a Chromium New Tab page that has not painted draws it")
        #expect(image.size == Self.size)
        #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.keepsClearPixels == true, "the picture keeps the page's clear areas")
        // Held: the next spare at this size and content takes no picture again.
        await withCheckedContinuation { done in view.redraw.rememberFrame(of: view, appearance: .darkAqua) { done.resume() } }
        #expect(page.calls.filter { $0.method == "Page.captureScreenshot" }.count == 1, "a frame already held is not pictured again")
    }

    @Test func aChromiumNewTabPageThatHasNotPaintedLiesOutsideTheWindowUntilItPaints() async throws {
        let (view, _) = try await chromiumNewTabPage()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(origin: .zero, size: Self.size))
        window.contentView = host
        host.addSubview(view)
        view.frame = host.bounds
        view.layoutSubtreeIfNeeded()
        let place = view.pageContent.frame
        #expect(!view.model.hasPainted)
        view.holdChromiumPageUntilPainted()
        view.layoutSubtreeIfNeeded()
        #expect(!view.pageContent.frame.intersects(view.bounds), "the page lies outside the pane until it paints: \(view.pageContent.frame)")
        #expect(!view.debugPageOnScreen)
        view.model.markPainted()
        view.layoutSubtreeIfNeeded()
        #expect(view.pageContent.frame == place, "the page is back in place in the turn it painted")
        #expect(!view.holdsPageAway)
    }
}
#endif
