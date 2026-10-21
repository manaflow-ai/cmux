import CoreGraphics

/// The compose field's glass as measured: a flat fill, a bright rim fading
/// inward at the top and bottom, and a thin dark side edge.
enum Glass {
    static func draw(_ ctx: CGContext, rect: CGRect, radius: CGFloat, fill: HomeColor) {
        let shape = RoundedRect.path(rect, radius: radius)
        Canvas.fill(ctx, shape, fill.cgColor)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let top: [(CGFloat, CGFloat)] = [(0, 0.27), (0.5, 0.165), (1, 0.06), (1.5, 0.048), (3, 0.024), (5, 0.012), (7, 0)]
        let bottom: [(CGFloat, CGFloat)] = [(0, 0.24), (0.5, 0.15), (1, 0.053), (1.5, 0.034), (3, 0.02), (6, 0.01), (8, 0)]
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        for (stops, fromTop) in [(top, true), (bottom, false)] {
            let span = stops.last?.0 ?? 1
            guard let gradient = CGGradient(colorsSpace: space, colors: stops.map { HomeColor.gray255(255, alpha: $0.1).cgColor } as CFArray,
                                            locations: stops.map { $0.0 / span }) else { continue }
            let y0 = fromTop ? rect.minY : rect.maxY
            let y1 = fromTop ? rect.minY + span : rect.maxY - span
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
        }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: -1, dy: min(radius, rect.height / 2) * 0.5))
        ctx.setStrokeColor(HomeColor.gray255(0, alpha: 0.6).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(RoundedRect.path(rect.insetBy(dx: -0.25, dy: -0.25), radius: radius + 0.25))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
