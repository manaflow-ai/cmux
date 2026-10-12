public import AppKit

/// A set's mark for one state as a still image, from the same geometry and
/// mark drawing the indicator layer uses, so a notification attachment
/// (cx-kxa2 notification landing) shows the icon the sidebar shows.
extension StatusIconSet {
    /// The still image of `state` (with `kind` for a waiting state) at
    /// `pointSize`, tinted with the theme roles resolved under `appearance`
    /// (nil: the current drawing appearance; inside a `ThemeScope.perform`
    /// the scope's colors). Nil for idle.
    @MainActor
    public func image(state: StatusIndicatorState, kind: StatusBlockedKind? = nil, pointSize: CGFloat, scale: CGFloat = 2,
                      appearance: NSAppearance? = nil) -> NSImage? {
        var state = state
        if let kind, case .waiting = state { state = .waiting(kind: kind) }
        let config = StatusIndicatorConfig(iconSet: self)
        let plan = StatusIndicatorPlan.make(state, style: config.settings.style, animates: false, set: self)
        let pixels = Int((pointSize * scale).rounded())
        guard plan.glyph != .none, pixels > 0,
              let mask = StatusGlyphArt.mask(plan, pixels: pixels, scale: scale, config: config) else { return nil }
        var colors: StatusIndicatorLayer.Colors?
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            colors = .current(loading: config.settings.color)
        }
        guard let color = colors?.color(for: plan.tint), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.clip(to: rect, mask: mask)
        context.setFillColor(color)
        context.fill(rect)
        guard let image = context.makeImage() else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: pointSize, height: pointSize))
        result.accessibilityDescription = tunableTitle
        return result
    }
}

/// Every plan glyph drawn still as an alpha mask (the first frame of an
/// animated one), with the layer's geometry.
@MainActor
enum StatusGlyphArt {
    static func mask(_ plan: StatusIndicatorPlan, pixels: Int, scale: CGFloat, config: StatusIndicatorConfig) -> CGImage? {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        let thickness = config.settings.thickness * scale
        context.setFillColor(gray: 0, alpha: 1)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch plan.glyph {
        case .none:
            return nil
        case .arc:
            let radius = rect.width / 2 - thickness / 2
            context.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: 0,
                           endAngle: 2 * .pi * config.arcLength, clockwise: false)
            context.setLineWidth(thickness)
            context.strokePath()
        case .ring(let progress):
            context.setLineWidth(thickness)
            context.setAlpha(config.trackOpacity)
            context.addPath(StatusGlyphGeometry.ringPath(in: rect, thickness: thickness))
            context.strokePath()
            context.setAlpha(1)
            let radius = max(0, rect.width / 2 - thickness / 2)
            context.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: .pi / 2,
                           endAngle: .pi / 2 - 2 * .pi * progress, clockwise: true)
            context.strokePath()
        case .native:
            guard let image = NativeSpinnerImage.image(side: CGFloat(pixels) / scale, scale: scale) else { return nil }
            context.draw(image, in: rect)
        case .braille:
            guard let image = BrailleSpinnerImage.images(side: CGFloat(pixels) / scale, scale: scale, family: config.terminalFontFamily).first
            else { return nil }
            context.draw(image, in: rect)
        case .dot:
            context.fillEllipse(in: StatusGlyphGeometry.dotRect(in: rect, scale: config.dotScale))
        case .check:
            context.addPath(StatusGlyphGeometry.checkPath(in: StatusGlyphGeometry.checkRect(in: rect)))
            context.setLineWidth(max(thickness, 1.25 * scale))
            context.strokePath()
        case .dots, .bars:
            let bars = plan.glyph == .bars
            let element = StatusGlyphGeometry.repeatedElement(in: rect.size, bars: bars)
            for index in 0..<StatusIndicatorLayer.dotsCount {
                let frame = element.frame.offsetBy(dx: element.step * CGFloat(index), dy: 0)
                var move = CGAffineTransform(translationX: frame.minX, y: frame.minY)
                if let path = StatusGlyphGeometry.repeatedElementPath(frame, bars: bars).copy(using: &move) {
                    context.addPath(path)
                }
            }
            context.fillPath()
        case .mark(let mark):
            StatusMarkArt.draw(mark, in: context, rect: rect)
        }
        return context.makeImage()
    }
}
