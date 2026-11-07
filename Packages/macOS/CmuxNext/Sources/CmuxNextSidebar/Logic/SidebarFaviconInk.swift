import CoreGraphics
import Foundation

/// What a favicon's opaque pixels look like, measured once per image (`SidebarFaviconRenditions`): whether it is one
/// grey ink (a GitHub mark, a Vercel triangle: low saturation, mostly one luminance) and that ink's luminance.
///
/// A monochrome favicon picked for a light page can vanish on a dark sidebar (Lawrence msg 19869, the GitHub mark as a
/// muddy circle); ``SidebarFaviconStyle`` uses this to redraw only those favicons, never a colourful one.
nonisolated struct SidebarFaviconInk: Equatable, Sendable {
    /// Low saturation and mostly one luminance: the favicon can draw as a template in any ink without losing detail.
    var isMonochrome: Bool
    /// The mean WCAG relative luminance (0 black, 1 white) of the opaque pixels.
    var luminance: Double

    /// Side of the bitmap the image is measured at: enough for a favicon's shape, cheap for a 256 px icon.
    static let sampleSide = 32
    /// Alpha (of 255) a pixel needs to count as ink, so the antialiased fringe does not count.
    static let opaque: UInt8 = 128
    /// Chroma (max minus min channel, 0...1) above which a pixel counts as coloured.
    static let colouredChroma = 0.18
    /// Share of coloured ink pixels a monochrome favicon may have (a stray tinted antialias pixel).
    static let colouredShare = 0.06
    /// How far (relative luminance) an ink pixel may sit from the median and still be the same ink.
    static let luminanceSpread = 0.12
    /// Share of ink pixels that must be within ``luminanceSpread`` of the median: "mostly one luminance".
    static let oneInkShare = 0.85

    /// Measures `image`, or nil when it has no opaque pixel.
    static func measure(_ image: CGImage) -> SidebarFaviconInk? {
        let side = sampleSide
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var luminances: [Double] = []
        luminances.reserveCapacity(side * side)
        var coloured = 0
        for index in 0..<(side * side) {
            let alpha = pixels[index * 4 + 3]
            guard alpha >= opaque else { continue }
            let a = Double(alpha)
            // Premultiplied: divide the alpha back out.
            let r = Double(pixels[index * 4]) / a, g = Double(pixels[index * 4 + 1]) / a, b = Double(pixels[index * 4 + 2]) / a
            if max(r, g, b) - min(r, g, b) > colouredChroma { coloured += 1 }
            luminances.append(relativeLuminance(r, g, b))
        }
        guard !luminances.isEmpty else { return nil }
        let count = Double(luminances.count)
        let mean = luminances.reduce(0, +) / count
        let median = luminances.sorted()[luminances.count / 2]
        let oneInk = Double(luminances.filter { abs($0 - median) <= luminanceSpread }.count) / count
        return SidebarFaviconInk(isMonochrome: Double(coloured) / count <= colouredShare && oneInk >= oneInkShare,
                                 luminance: mean)
    }

    /// WCAG contrast ratio of this ink on a ground of relative luminance `ground` (1...21).
    func contrast(onGround ground: Double) -> Double {
        let lighter = max(luminance, ground), darker = min(luminance, ground)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// WCAG relative luminance of an sRGB colour (channels 0...1).
    static func relativeLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
