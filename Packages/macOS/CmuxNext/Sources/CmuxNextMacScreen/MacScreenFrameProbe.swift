import CoreVideo
import Foundation

/// How much a decoded frame's picture varies: the mean and variance of its luma (the Y plane, 0-255) over a
/// 32 x 32 grid of samples. `mac_screen.state` reports the latest as `luma_mean` and `luma_variance`, so a check
/// can tell a real picture (a desktop with windows and text: variance in the hundreds or more) from a flat one
/// (black, grey or one colour: near 0) without a window screenshot, which paints the pane's child window grey.
/// Two numbers per measured frame, never a pixel of the screen.
nonisolated struct MacScreenFrameProbe: Equatable, Sendable {
    static let grid = 32
    var mean: Double
    var variance: Double

    /// The probe of `values` (luma samples); nil for none.
    static func of(_ values: [UInt8]) -> MacScreenFrameProbe? {
        guard !values.isEmpty else { return nil }
        let count = Double(values.count)
        let mean = values.reduce(0.0) { $0 + Double($1) } / count
        let variance = values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / count
        return MacScreenFrameProbe(mean: mean, variance: variance)
    }

    /// The probe of a decoded frame (NV12, full or video range, as the decoder outputs): `grid` x `grid`
    /// luma samples at cell centers, 1,024 reads. Nil for another pixel format or an unreadable buffer.
    static func measure(_ buffer: CVPixelBuffer) -> MacScreenFrameProbe? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        var values: [UInt8] = []
        values.reserveCapacity(grid * grid)
        for row in 0 ..< grid {
            let y = min(height - 1, (2 * row + 1) * height / (2 * grid))
            for column in 0 ..< grid {
                let x = min(width - 1, (2 * column + 1) * width / (2 * grid))
                values.append(luma[y * stride + x])
            }
        }
        return of(values)
    }
}
