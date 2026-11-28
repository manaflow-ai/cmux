import CoreGraphics

/// Whether a thumbnail holds a real picture (`debug.hover_sweep`, R131): its
/// size and the luminance mean and variance of a 16x16 grayscale copy. A
/// blank capture (one flat color) has a variance near 0.
struct ThumbnailStats: Equatable, Sendable {
    var width: Int
    var height: Int
    /// Luminance mean and variance over the downsampled copy (0...255 scale).
    var mean: Double
    var variance: Double

    /// A flat image (blank page capture, solid placeholder) is under this.
    static let blankVariance = 4.0
    var isBlank: Bool { variance < Self.blankVariance }

    /// Computes the stats on a background task.
    static func measure(_ image: CGImage) async -> ThumbnailStats? {
        await Task.detached(priority: .utility) { measured(image) }.value
    }

    nonisolated static func measured(_ image: CGImage) -> ThumbnailStats? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let values = pixels.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return ThumbnailStats(width: image.width, height: image.height, mean: mean, variance: variance)
    }
}
