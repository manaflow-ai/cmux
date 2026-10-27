#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

extension VNCCursor {
    public func makeImage() -> CGImage? {
        guard !isEmpty else { return nil }
        // The words as little-endian bytes (B G R A), the bitmap info below.
        var data = Data(capacity: pixels.count * 4)
        for pixel in pixels {
            data.append(UInt8(truncatingIfNeeded: pixel))
            data.append(UInt8(truncatingIfNeeded: pixel >> 8))
            data.append(UInt8(truncatingIfNeeded: pixel >> 16))
            data.append(UInt8(truncatingIfNeeded: pixel >> 24))
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        // SAFETY: a nil decode array: CGImage reads no decode values; the provider owns the bytes.
        return unsafe CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent)
    }
}
#endif
