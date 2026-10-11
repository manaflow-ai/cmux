public import AppKit
import CmuxNextDesign

extension AgentPaneView {
    /// An image of the page as shown (the next launch draws it until this
    /// page paints again), on the page's background: the page is
    /// transparent, and the saved JPEG would turn that white.
    public func pageImage() async -> NSImage? {
        var background = AgentPaneTheme.underPageColor(themeTokens, surface: surfaceKind)
        background.alpha = 1
        guard let page = await snapshotPage() else { return nil }
        guard let image = page.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return page }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(background.cgColor)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage().map { NSImage(cgImage: $0, size: page.size) } ?? page
    }
}
