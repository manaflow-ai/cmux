import CoreGraphics
import Foundation

/// Immutable Core Graphics presentation created from host-owned frame bytes.
// SAFETY: CGImage and its provider are immutable after construction. The
// provider retains a deep CFData copy and has no shared-memory backing.
struct SimulatorFramePresentation: @unchecked Sendable {
    private static let deviceRGBColorSpace = CGColorSpaceCreateDeviceRGB()

    let image: CGImage
    let sequence: UInt64

    init?(snapshot: SimulatorFrameSnapshot) {
        let (expectedBytesPerRow, rowOverflow) = snapshot.width.multipliedReportingOverflow(by: 4)
        let (expectedByteCount, countOverflow) = snapshot.bytesPerRow
            .multipliedReportingOverflow(by: snapshot.height)
        guard snapshot.width > 0,
              snapshot.height > 0,
              !rowOverflow,
              !countOverflow,
              snapshot.bytesPerRow == expectedBytesPerRow,
              snapshot.pixels.count == expectedByteCount,
              let provider = CGDataProvider(data: snapshot.pixels as CFData),
              let image = CGImage(
                width: snapshot.width,
                height: snapshot.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: snapshot.bytesPerRow,
                space: Self.deviceRGBColorSpace,
                bitmapInfo: [
                    .byteOrder32Little,
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
                ],
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        self.image = image
        sequence = snapshot.sequence
    }
}
