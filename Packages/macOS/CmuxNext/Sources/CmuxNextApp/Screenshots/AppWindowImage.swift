import AppKit
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextPages
import CmuxNextScreenshots

/// One of this app's main windows as on screen, for `cmux window|pane|tab
/// screenshot`: the window server's image of the window and its Chromium
/// page windows (``NSWindow/screenshotImage(includeChild:)``: Ghostty's
/// Metal terminals and WebKit pages included, no Screen Recording grant,
/// background and covered windows too), then Chromium's own image of each
/// shown page painted over its page area (without the grant the window
/// server leaves out what Chromium's GPU process draws), then the overlay
/// panels, open menus and the app's other windows above the content. Nothing is focused, raised or
/// activated.
@MainActor
struct AppWindowImage {
    let services: AppServices

    /// The window's image at its backing scale, raw: only a person's own run in the app gets
    /// this (``ScreenshotHandlers/isPersonsRun(_:)``). An agent's or a script's run goes through
    /// ``maskedCapture(_:)``, which covers every page area and chat.
    /// - Throws: ``WindowScreenshotFailure`` when the window server gives no image.
    func capture(_ window: NSWindow) async throws -> CGImage {
        let base = try await window.screenshotImage(includeChild: WindowOverlayHost.isPageWindow)
        var layers: [WindowImageLayer] = []
        for (page, rect) in DebugWindowSnapshot.chromiumPages(in: window, services: services) {
            // A page that cannot give its image keeps the window server's
            // pixels there (its background without the grant).
            guard let image = try? await page.snapshot() else { continue }
            let holes = page.pageWindowHoles.map { page.contentView.convert($0, to: nil) }
            layers.append(.page(image, rect, holes: holes))
        }
        // React pages on the Chromium engine (the agent page, Settings) draw the same way.
        for (page, rect) in PageRegistry.shownChromiumPages(in: window) {
            guard let image = await page.chromiumImage() else { continue }
            layers.append(.page(image, rect))
        }
        // The panel and floating-window captures run off the main actor too; main reads only their window numbers.
        if let panels = await window.childWindowsImage(includeChild: { !WindowOverlayHost.isPageWindow($0) }) {
            layers.append(.window(panels))
        }
        if let floating = await window.floatingWindowsImage() { layers.append(.window(floating.image)) }
        // The full-resolution redraw runs off the main actor.
        return await WindowImageLayer.compositedOffMain(base: base, windowSize: window.frame.size, layers: layers) ?? base
    }

    /// The window for an agent or a script, with every browser page and chat masked
    /// (``ScreenshotMask``): the window alone, without its child and floating windows (an
    /// overlay, hover card, drag ghost or menu can show a page) and without Chromium's browser
    /// pages (their pixels are only in their child windows), then the app's own Chromium pages
    /// painted in, then the masks on top. It fails closed: a mask that cannot be painted, or a
    /// window that keeps animating or resizing, refuses the capture instead of giving its pixels.
    /// - Returns: The image and how many areas it masks.
    /// - Throws: ``WindowScreenshotFailure`` or ``ScreenshotMask/Failure``.
    static func maskedCapture(_ window: NSWindow) async throws -> (image: CGImage, masked: Int) {
        for _ in 0..<ScreenshotMask.attempts {
            let sampler = ScreenshotMask.Sampler(window: window)
            defer { sampler.stop() }
            await ScreenshotMask.waitToSettle()
            let base = try await window.screenshotImage(includeChild: { _ in false })
            var layers: [WindowImageLayer] = []
            for (page, rect) in PageRegistry.shownChromiumPages(in: window) where !ScreenshotMask.isCovered(page) {
                guard let image = await page.chromiumImage() else { continue }
                layers.append(.page(image, rect))
            }
            // The last reading follows the last await, so nothing changes before the paint.
            sampler.stop()
            let mask = sampler.mask
            guard mask.isSettled else { continue }
            layers += mask.regions.map(WindowImageLayer.mask)
            guard let image = WindowImageLayer.composite(base: base, window: window, layers: layers) else {
                if mask.regions.isEmpty { return (base, 0) }
                throw ScreenshotMask.Failure.unmaskable
            }
            return (image, mask.regions.count)
        }
        throw ScreenshotMask.Failure.unsettled
    }
}
