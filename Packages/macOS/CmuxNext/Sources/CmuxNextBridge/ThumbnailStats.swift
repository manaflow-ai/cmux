public import CoreGraphics

/// Whether a thumbnail holds a real picture (hover cards, `debug.hover_sweep`, R131): its size, the luminance mean
/// and variance of a 128x128 grayscale copy, and how many of its pixels stand out from the image's ground (its
/// median). A blank capture (one flat color, a page that had not painted, a cleared terminal) has none.
///
/// The user, 2026-11-24 (hover cards showing an empty tile for a terminal with output and for a chat): the test was a
/// variance under 4 over a 16x16 copy, and a dark pane with a few short lines of text (a prompt and one line of
/// output, a chat's first turn) moves only a handful of those 256 cells by a little: its variance is about 2, so its
/// real picture was thrown away as blank. A line of text is a run of clearly brighter (or darker) pixels at 128x128,
/// however little of the pane it fills.
public struct ThumbnailStats: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Luminance mean and variance over the downsampled copy (0...255 scale).
    public var mean: Double
    public var variance: Double
    /// Pixels of the 128x128 copy more than ``detailDelta`` from its median luminance.
    public var detailPixels: Int

    /// A pixel this far from the ground is content (JPEG noise and a theme's faint gradient stay under it).
    public nonisolated static let detailDelta = 12
    /// At least this many content pixels make a picture: two short lines on a 1800 px pane are about 19; a lone prompt glyph is under it.
    public nonisolated static let detailMinimum = 6
    public var isBlank: Bool { detailPixels < Self.detailMinimum }

    /// Computes the stats on a background task.
    public static func measure(_ image: CGImage) async -> ThumbnailStats? {
        await Task.detached(priority: .utility) { measured(image) }.value
    }

    public nonisolated static func measured(_ image: CGImage) -> ThumbnailStats? {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high  // averages the source area, so thin text is not skipped by sampling
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let values = pixels.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let ground = Int(pixels.sorted()[pixels.count / 2])
        let detail = pixels.reduce(0) { $0 + (abs(Int($1) - ground) > detailDelta ? 1 : 0) }
        return ThumbnailStats(width: image.width, height: image.height, mean: mean, variance: variance, detailPixels: detail)
    }
}
