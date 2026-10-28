package import AppKit

extension WindowImageLayer {
    /// `views` (layer-backed views of a window `windowSize` points large) rendered at `scale` inside the
    /// page rects of `layers`, less their holes: a ``window(_:)`` layer to paint after the page images;
    /// nil with no view or no page layer.
    ///
    /// A snapshot paints each page's own image over its rect, above the window's base image. Views
    /// drawn above a page in the window's own view tree (the overlay planes over a Chromium Host page,
    /// a view as Chrome's `RenderWidgetHostViewCocoa` is) are in the base image under it; this paints
    /// them again inside the page rects only, so a translucent dim is painted once everywhere.
    @MainActor
    package static func views(_ views: [NSView], overPagesOf layers: [WindowImageLayer], windowSize: CGSize,
                              scale: CGFloat) -> WindowImageLayer? {
        var areas: [(rect: NSRect, holes: [NSRect])] = []
        for case .page(_, let rect, let holes) in layers { areas.append((rect, holes)) }
        let width = Int((windowSize.width * scale).rounded())
        let height = Int((windowSize.height * scale).rounded())
        guard !areas.isEmpty, !views.isEmpty, width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Window coordinates and the bitmap both have a bottom-left origin.
        context.scaleBy(x: scale, y: scale)
        for area in areas {
            context.saveGState()
            let clip = CGMutablePath()
            clip.addRect(area.rect)
            for hole in area.holes { clip.addRect(hole) }
            context.addPath(clip)
            context.clip(using: .evenOdd)
            for view in views {
                guard let layer = view.layer else { continue }
                let rect = view.convert(view.bounds, to: nil)
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.minY)
                if layer.contentsAreFlipped() {
                    context.translateBy(x: 0, y: rect.height)
                    context.scaleBy(x: 1, y: -1)
                }
                layer.render(in: context)
                context.restoreGState()
            }
            context.restoreGState()
        }
        return context.makeImage().map(WindowImageLayer.window)
    }
}
