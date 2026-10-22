import AppKit
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextPages

/// One of this app's main windows as on screen, for `cmux window|pane|tab
/// screenshot`: the window server's image of the window with its child
/// windows and the app's menus and popovers over it, composited together so
/// glass over the window blurs it (``NSWindow/screenshotImageWithOverlays()``:
/// Ghostty's Metal terminals and WebKit pages included, no Screen Recording
/// grant, background and covered windows too), then Chromium's own image of
/// each shown page painted over its page area (without the grant the window
/// server leaves out what Chromium's GPU process draws), then the overlays
/// again where they cover a page. Without that image, the window and its page
/// windows (``NSWindow/screenshotImage(includeChild:)``) with the overlay
/// panels and open menus painted on top. Nothing is focused, raised or activated.
@MainActor
struct AppWindowImage {
    let services: AppServices

    /// The window's image at its backing scale.
    /// - Throws: ``WindowScreenshotFailure`` when the window server gives no image.
    func capture(_ window: NSWindow) async throws -> CGImage {
        let together = window.screenshotImageWithOverlays()?.image
        let base: CGImage
        if let together { base = together } else { base = try await window.screenshotImage(includeChild: WindowOverlayHost.isPageWindow) }
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
        if together != nil {
            // A page image covered the panels, popovers and menus over its page: they come back.
            if !layers.isEmpty, let overlays = window.overlaysSnapshot(includeChild: { !WindowOverlayHost.isPageWindow($0) }) {
                layers.append(.overlay(base, coverage: overlays))
            }
        } else {
            if let panels = window.childWindowsSnapshot(includeChild: { !WindowOverlayHost.isPageWindow($0) }) {
                layers.append(.window(panels))
            }
            if let floating = window.floatingWindowsSnapshot() { layers.append(.window(floating.image)) }
        }
        return WindowImageLayer.composite(base: base, window: window, layers: layers) ?? base
    }
}
