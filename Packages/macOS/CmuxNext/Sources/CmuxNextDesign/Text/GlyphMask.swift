import AppKit
import CmuxNextCompat

/// The one glyph drawing of the text classes whose color blends (``ChromeLabel``,
/// ``ChromeTextLayer``; cx-8w027.12).
///
/// The glyphs draw once into an image whose alpha is their coverage. A fill layer whose
/// `backgroundColor` is the text color shows through that image, so a color change blends on the
/// render server and draws no glyphs.
///
/// The coverage is the coverage AppKit gives a label on screen. Font smoothing is on (on macOS
/// that is stem darkening, not subpixel color), and the ink is the text's own color: Core Graphics
/// darkens stems by the ink's luminance, in four steps (measured on macOS 27 at 13 pt, 2x: near-white
/// ink covers 15% more than black, so a mask drawn in black is 13% light on a dark theme). The
/// fill carries the ink's alpha; where the alpha changes the stems too (macOS 26.5), the glyphs
/// draw at it and the mask is their coverage per unit of alpha (``alphaChangesStems``).
/// ``weight(of:)`` names the step of an ink: a color change inside one step keeps the image.
nonisolated enum GlyphMask {
    /// The stem step `ink` draws at (nil: black). Equal values draw equal coverage.
    ///
    /// Core Graphics does not publish the steps, so this asks it: the coverage of a reference
    /// string drawn in `ink`, per unit of its alpha (see ``alphaChangesStems``), cached per 8-bit sRGB
    /// color and alpha.
    static func weight(of ink: CGColor?) -> Int {
        let rgb = components(of: ink), alpha = drawnAlpha(ink)
        let key = (rgb + [alpha]).reduce(UInt32(0)) { $0 << 8 | UInt32(($1 * 255).rounded()) }
        if let known = weights.withLock({ $0[key] }) { return known }
        let measured = Int((Double(measure(rgb, alpha: alpha, scale: 2)) / Double(alpha)).rounded())
        weights.withLock { cache in
            if cache.count >= 512 { cache.removeAll() }
            cache[key] = measured
        }
        return measured
    }

    /// The glyph coverage of `draw` over `size` points at `scale`, top row first.
    ///
    /// `draw` runs in a top-down point space (origin at the top left, like a flipped view) with
    /// font smoothing on, `ink` as the fill color (opaque, or at its own alpha where the alpha
    /// changes the stems: ``alphaChangesStems``) and a flipped `NSGraphicsContext` current, so Core
    /// Text and AppKit cells draw into it alike. An ink drawn at its alpha is divided out of the
    /// image again: the fill carries the alpha, the mask the coverage per unit of it. The image is
    /// whole pixels, rounded up.
    static func image(size: CGSize, scale: CGFloat, ink: CGColor?, draw: (CGContext, CGColor) -> Void) -> CGImage? {
        let scale = max(scale, 1)
        let (width, height) = pixels(size, scale: scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        // What AppKit enables for a label (a transparent layer's context leaves it off).
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        let alpha = drawnAlpha(ink)
        let drawn = drawnInk(ink, alpha: alpha)
        ctx.setFillColor(drawn)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(ctx, drawn)
        NSGraphicsContext.restoreGraphicsState()
        if alpha < 1 { divide(ctx, by: alpha) }
        return ctx.makeImage()
    }

    /// Whether Core Graphics darkens the stems of an ink by its alpha too: macOS 26.5 does (an ink
    /// at alpha 0.5 covers about 1% more per unit of alpha than the opaque ink, at 0.85 about
    /// 0.35%; a stock label in `labelColor` is that much heavier), macOS 27 does not. Asked once,
    /// as ``weight(of:)`` asks for the steps: white and black at alpha 0.5 against opaque, at 1x
    /// and 2x.
    static let alphaChangesStems: Bool = [CGFloat(1), 2].contains { scale in
        [[CGFloat(1), 1, 1], [0, 0, 0]].contains { rgb in
            let opaque = Double(measure(rgb, alpha: 1, scale: scale)), half = Double(measure(rgb, alpha: 0.5, scale: scale)) / 0.5
            return opaque > 0 && abs(half - opaque) > opaque * 0.002
        }
    }

    /// The alpha the glyphs of `ink` draw at: its own where it changes the stems, else 1. An
    /// invisible ink draws opaque, so a fade out of it keeps its glyphs.
    private static func drawnAlpha(_ ink: CGColor?) -> CGFloat {
        guard alphaChangesStems, let ink, let alpha = ink.converted(to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                                                   intent: .defaultIntent, options: nil)?.alpha else { return 1 }
        let quantized = (min(max(alpha, 0), 1) * 255).rounded() / 255
        return quantized > 0 ? quantized : 1
    }

    /// Scales every (premultiplied) channel of `ctx`'s pixels by 1 / `alpha`: coverage per unit of alpha.
    private static func divide(_ ctx: CGContext, by alpha: CGFloat) {
        guard let data = ctx.data else { return }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * ctx.height)
        let factor = 1 / Double(alpha)
        var lookup = [UInt8](repeating: 0, count: 256)
        for value in 0..<256 { lookup[value] = UInt8(min(255, (Double(value) * factor).rounded())) }
        for row in 0..<ctx.height {
            let start = row * ctx.bytesPerRow
            for index in start..<(start + ctx.width * 4) { bytes[index] = lookup[Int(bytes[index])] }
        }
    }

    /// Sizes `glyphs` (the mask of `fill`) to the image ``image(size:scale:ink:draw:)`` makes for
    /// `fill`'s bounds, its top edge on `fill`'s top edge: the image shows at its own pixel size,
    /// never resampled.
    static func place(_ glyphs: CALayer, in fill: CALayer, scale: CGFloat) {
        let scale = max(scale, 1)
        let (width, height) = pixels(fill.bounds.size, scale: scale)
        let size = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let top = rendersTopDown(fill) ? 0 : fill.bounds.height - size.height
        let frame = CGRect(origin: CGPoint(x: 0, y: top), size: size)
        if glyphs.frame != frame { glyphs.frame = frame }
        if glyphs.contentsScale != scale { glyphs.contentsScale = scale }
    }

    private static let weights = Mutex<[UInt32: Int]>([:])

    /// True when `layer`'s space runs top-down on screen (the flags of the layer and its
    /// ancestors combine; the root's space is bottom-up), as `ScrollEdgeFadeView.rendersTopDown`.
    private static func rendersTopDown(_ layer: CALayer) -> Bool {
        var flipped = false
        var node: CALayer? = layer
        while let current = node {
            if current.isGeometryFlipped { flipped.toggle() }
            node = current.superlayer
        }
        return flipped
    }

    private static func pixels(_ size: CGSize, scale: CGFloat) -> (Int, Int) {
        (Int((size.width * scale).rounded(.up)), Int((size.height * scale).rounded(.up)))
    }

    private static func components(of ink: CGColor?) -> [CGFloat] {
        guard let ink, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = ink.converted(to: srgb, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3 else { return [0, 0, 0] }
        return parts.prefix(3).map { min(max($0, 0), 1) }
    }

    /// `ink` in sRGB at `alpha`.
    private static func drawnInk(_ ink: CGColor?, alpha: CGFloat) -> CGColor {
        let rgb = components(of: ink)
        return CGColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha)
    }

    /// The alpha sum of a reference string drawn in `rgb` at `alpha` and `scale`, smoothed.
    private static func measure(_ rgb: [CGFloat], alpha: CGFloat, scale: CGFloat) -> Int {
        let width = 96, height = 40
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setFillColor(CGColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hlm", attributes: [
            .font: NSFont.systemFont(ofSize: TypeScale.body),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        ctx.textPosition = CGPoint(x: 2, y: 5)
        CTLineDraw(line, ctx)
        guard let data = ctx.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var sum = 0
        for pixel in 0..<(width * height) { sum += Int(bytes[pixel * 4 + 3]) }
        return sum
    }
}
