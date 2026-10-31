import AppKit
import CmuxNextDesign

/// What a saved page image (the next launch's first frame, `AgentPaneLaunchImages`) draws where
/// the page itself is clear.
///
/// A page whose background is opaque (an opaque window) is flattened over that color, so its JPEG
/// never turns the clear pixels white and flashes over a dark pane. A page that is transparent
/// (the New Tab page, or any page over a see-through window or a background image) keeps its
/// clear pixels: the window's backdrop, which paints its art from a snapshot in the first frame,
/// shows through the image as it shows through the live page. Flattening it painted the solid
/// theme color over the art until the live page drew.
enum PageImageBackground {
    /// Whether `color` hides what is under it (an opaque window), so a page drawn over it needs no alpha.
    static func isOpaque(_ color: ThemeRGB) -> Bool { color.alpha >= 1 }

    /// The picture a pane may draw for its page until the live page paints, or nil when there is none.
    ///
    /// A picture that cannot keep the page's clear pixels (a Chromium capture is a JPEG with no
    /// alpha, `PageWebView.snapshotKeepsClearAreas`) shows those pixels black. A page that paints an
    /// opaque background of its own (`pageIsOpaque`: an opaque window, or a surface background that
    /// hides the window) has no clear pixels, so its picture still covers. A page that is clear
    /// anywhere (a glass, frosted or see-through window, or a background image) has them: its picture
    /// is no cover at all, and the pane shows its loading state on the window's own backdrop instead.
    /// Leo, 2026-10-26: "on restarting after an update/maybe in general, we dont wanna see a black
    /// background on the agent chat".
    ///
    /// - Parameters:
    ///   - page: The picture; nil when none was taken.
    ///   - color: The color the pane shows under the page, which an opaque one is flattened over.
    ///   - pageIsOpaque: Whether the page paints an opaque background of its own.
    ///   - keepsClearAreas: Whether the picture keeps the page's clear pixels (it has alpha).
    /// Whether a saved `image` may stand in for its page: it keeps clear pixels (it has alpha), or
    /// the page paints an opaque background so it has none to lose (``cover(_:color:pageIsOpaque:keepsClearAreas:)``).
    @MainActor
    static func covers(_ image: NSImage, pageIsOpaque: Bool) -> Bool {
        pageIsOpaque || image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.keepsClearPixels == true
    }

    @MainActor
    static func cover(_ page: NSImage?, color: ThemeRGB, pageIsOpaque: Bool, keepsClearAreas: Bool) -> NSImage? {
        guard let page, keepsClearAreas || pageIsOpaque else { return nil }
        return fill(page, color)
    }

    /// `page` drawn over `color` at the snapshot's pixel size when `color` is opaque; `page`
    /// itself, clear pixels kept, when the page is transparent (`color` with alpha below 1).
    @MainActor
    static func fill(_ page: NSImage, _ color: ThemeRGB) -> NSImage {
        guard isOpaque(color) else { return page }
        guard let image = page.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return page }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(color.cgColor)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage().map { NSImage(cgImage: $0, size: page.size) } ?? page
    }
}
