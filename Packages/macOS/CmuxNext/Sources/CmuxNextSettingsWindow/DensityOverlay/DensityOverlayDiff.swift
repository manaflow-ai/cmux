public import CoreGraphics

/// How two images of the same chrome differ, pixel by pixel: the Density Overlay Playground's count of where cmux's
/// tab bar and omnibar still miss the reference (a Helium or Chrome capture).
///
/// Both images are drawn into one sRGB RGBA buffer the size of the smaller one, the reference moved by `offset` pixels,
/// and a pixel differs when any channel differs by more than `threshold` (of 255), so anti-aliasing noise stays out.
///
/// ```swift
/// let diff = DensityOverlayDiff(live: cmux, reference: helium, threshold: 24)
/// diff.differing // 0 when the two match
/// ```
public nonisolated struct DensityOverlayDiff: Equatable, Sendable {
    /// Pixels compared.
    public let total: Int
    /// Pixels that differ by more than the threshold.
    public let differing: Int
    /// The smallest rectangle, in pixels from the top left, that holds every differing pixel; nil when none differ.
    public let bounds: CGRect?

    /// Compares `live` with `reference`.
    /// - Parameters:
    ///   - live: The app's own capture.
    ///   - reference: The image to match.
    ///   - offset: How far the reference is moved, in pixels (right and down positive).
    ///   - threshold: The largest channel difference that still counts as the same, 0...255.
    public init(live: CGImage, reference: CGImage, offset: CGPoint = .zero, threshold: Int = 24) {
        let width = min(live.width, reference.width), height = min(live.height, reference.height)
        guard width > 0, height > 0, let a = Self.pixels(live, width: width, height: height, offset: .zero),
              let b = Self.pixels(reference, width: width, height: height, offset: offset) else {
            (total, differing, bounds) = (0, 0, nil)
            return
        }
        var count = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let delta = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
                guard delta > threshold else { continue }
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        total = width * height
        differing = count
        bounds = count == 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The share of pixels that differ, 0...1.
    public var fraction: Double { total == 0 ? 0 : Double(differing) / Double(total) }

    /// `image` drawn on opaque white into a `width` x `height` RGBA buffer, its top left at `offset` (pixels, y down).
    private static func pixels(_ image: CGImage, width: Int, height: Int, offset: CGPoint) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)) // colour-allow: the diff buffer's ground, data not UI
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            // The context's origin is the bottom left: the image's top sits at the buffer's top, moved down by offset.y.
            context.draw(image, in: CGRect(x: offset.x, y: CGFloat(height - image.height) - offset.y,
                                           width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        return drawn ? bytes : nil
    }
}
