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
/// ink's alpha does not change the stems, so the ink draws opaque and the fill carries the alpha.
/// ``weight(of:)`` names the step of an ink: a color change inside one step keeps the image.
nonisolated enum GlyphMask {
    /// The stem step `ink` draws at (nil: black). Equal values draw equal coverage.
    ///
    /// Core Graphics does not publish the steps, so this asks it: the coverage of a reference
    /// string drawn in `ink`, cached per 8-bit sRGB color.
    static func weight(of ink: CGColor?) -> Int {
        let rgb = components(of: ink)
        let key = rgb.reduce(UInt32(0)) { $0 << 8 | UInt32(($1 * 255).rounded()) }
        if let known = weights.withLock({ $0[key] }) { return known }
        let measured = measure(rgb)
        weights.withLock { cache in
            if cache.count >= 512 { cache.removeAll() }
            cache[key] = measured
        }
        return measured
    }

    /// The glyph coverage of `draw` over `size` points at `scale`, top row first.
    ///
    /// `draw` runs in a top-down point space (origin at the top left, like a flipped view) with
    /// font smoothing on, `ink` (opaque) as the fill color and a flipped `NSGraphicsContext` current,
    /// so Core Text and AppKit cells draw into it alike. The image is whole pixels, rounded up.
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
        let opaque = opaqueInk(ink)
        ctx.setFillColor(opaque)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(ctx, opaque)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
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

    /// `ink` in sRGB at full alpha.
    private static func opaqueInk(_ ink: CGColor?) -> CGColor {
        let rgb = components(of: ink)
        return CGColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
    }

    /// The alpha sum of a reference string drawn in `rgb`, smoothed.
    private static func measure(_ rgb: [CGFloat]) -> Int {
        let width = 96, height = 40
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.scaleBy(x: 2, y: 2)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setFillColor(CGColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hlm", attributes: [
            .font: NSFont.systemFont(ofSize: TypeScale.Base.body),
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
