#if canImport(CCmuxNativeTranscriptFFI)
import CCmuxNativeTranscriptFFI
import CoreGraphics
import CoreText
import Foundation
import Metal

/// The glyph atlas of one native transcript: one R8 texture of `atlas_px` squared, filled by CoreText as the scene
/// asks (`cmux_nt_take_raster_requests`), on the render thread. The scene owns the packing; this only draws each
/// requested glyph into the slot it was given and uploads that slot's pixels.
// crash-allow: used by the render thread only (made there, drawn there); CTFont is immutable and thread-safe.
nonisolated final class NativeTranscriptAtlas: @unchecked Sendable {
    static let fontSize: CGFloat = 13
    static let lineHeight: CGFloat = 20
    static let atlasPixels: UInt32 = 2048
    let texture: any MTLTexture
    let metrics: CmuxNtMetrics
    private let text: CTFont
    private let mono: CTFont
    private let scale: CGFloat
    private var requests = [CmuxNtRasterRequest](repeating: CmuxNtRasterRequest(), count: 256)
    private(set) var rasterized = 0

    init?(device: any MTLDevice, scale: CGFloat) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: Int(Self.atlasPixels), height: Int(Self.atlasPixels), mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "native transcript glyph atlas"
        self.texture = texture
        self.scale = scale
        text = CTFontCreateUIFontForLanguage(.system, Self.fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, Self.fontSize, nil)
        mono = CTFontCreateWithName("Menlo" as CFString, Self.fontSize - 1, nil)
        metrics = Self.metrics(text: text, mono: mono, scale: scale)
    }

    /// Draws every glyph the scene placed and not yet drawn, then tells it the slots are filled. Returns how many.
    @discardableResult
    func fill(_ scene: OpaquePointer) -> Int {
        var drawn = 0
        // At most 64 batches of 256 per frame (16,384 glyphs: more than an atlas holds); the rest go next frame.
        for _ in 0..<64 {
            let count = Int(requests.withUnsafeMutableBufferPointer {
                cmux_nt_take_raster_requests(scene, $0.baseAddress, UInt32($0.count))
            })
            for index in 0..<count { draw(requests[index]) }
            drawn += count
            if count < requests.count { break }
        }
        if drawn > 0 { cmux_nt_glyphs_ready(scene) }
        rasterized += drawn
        return drawn
    }

    // perf-hot: 1ms native-transcript-glyphs (a new glyph's slot: CoreText into a small gray bitmap, one upload)
    private func draw(_ request: CmuxNtRasterRequest) {
        let width = Int(request.slot_w), height = Int(request.slot_h)
        guard width > 0, height > 0, let scalar = Unicode.Scalar(request.scalar) else { return }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let font = request.font == 1 ? mono : text
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setAllowsFontSmoothing(false)
            context.setShouldAntialias(true)
            context.setFillColor(gray: 1, alpha: 1)
            context.scaleBy(x: scale, y: scale)
            let (glyph, drawFont) = Self.glyph(for: scalar, in: font)
            guard glyph != 0 else { return }
            // CoreGraphics is y-up; the slot's top is the line's top, the baseline `ascent` below it (the code
            // font's line is two points shorter, its baseline one point higher).
            let baseline = CGFloat(height) / scale - CGFloat(metrics.ascent) + (request.font == 1 ? 1 : 0)
            var position = CGPoint(x: 1, y: baseline)
            var one = glyph
            CTFontDrawGlyphs(drawFont, &one, &position, 1, context)
        }
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(Int(request.slot_x), Int(request.slot_y), width, height),
                            mipmapLevel: 0, withBytes: base, bytesPerRow: width)
        }
    }

    /// The glyph of `scalar` in `font`, or in the font CoreText falls back to for it.
    private static func glyph(for scalar: Unicode.Scalar, in font: CTFont) -> (CGGlyph, CTFont) {
        let units = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        if CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), glyphs[0] != 0 { return (glyphs[0], font) }
        let string = String(Character(scalar)) as CFString
        let fallback = CTFontCreateForString(font, string, CFRange(location: 0, length: CFStringGetLength(string)))
        guard CTFontGetGlyphsForCharacters(fallback, units, &glyphs, units.count) else { return (0, font) }
        return (glyphs[0], fallback)
    }

    /// The scene's font metrics: printable ASCII advances of the text font, its line box, the code font's.
    private static func metrics(text: CTFont, mono: CTFont, scale: CGFloat) -> CmuxNtMetrics {
        var metrics = CmuxNtMetrics()
        let characters = (32...126).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(text, characters, &glyphs, characters.count)
        var sizes = [CGSize](repeating: .zero, count: characters.count)
        CTFontGetAdvancesForGlyphs(text, .horizontal, glyphs, &sizes, characters.count)
        withUnsafeMutableBytes(of: &metrics.advances) { raw in
            let advances = raw.bindMemory(to: Float.self)
            for index in 0..<min(advances.count, sizes.count) { advances[index] = Float(sizes[index].width) }
        }
        let widest = sizes.map(\.width).max() ?? fontSize
        var monoGlyph: CGGlyph = 0
        var m = UniChar(77)  // "M"
        _ = CTFontGetGlyphsForCharacters(mono, &m, &monoGlyph, 1)
        var monoSize = CGSize.zero
        CTFontGetAdvancesForGlyphs(mono, .horizontal, &monoGlyph, &monoSize, 1)
        let box = CTFontGetAscent(text) + CTFontGetDescent(text)
        metrics.fallback_advance = Float(fontSize)
        metrics.line_height = Float(lineHeight)
        metrics.ascent = Float(((lineHeight - box) / 2 + CTFontGetAscent(text)).rounded())
        // A slot one point wider than the widest ASCII glyph on each side: italics and fallback glyphs overhang.
        metrics.glyph_w = Float((max(widest, fontSize) + 2).rounded(.up))
        metrics.glyph_h = Float(lineHeight)
        metrics.mono_advance = Float(monoSize.width)
        metrics.mono_line_height = Float(lineHeight - 2)
        metrics.scale = Float(scale)
        metrics.atlas_px = atlasPixels
        return metrics
    }
}
#endif
