import CoreGraphics
import Foundation

/// One physical display inside the framebuffer (ExtendedDesktopSize).
public struct VNCScreen: Sendable, Equatable {
    public var id: UInt32
    /// In framebuffer pixels.
    public var frame: CGRect

    public init(id: UInt32, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// The remote cursor shape (Cursor pseudo-encoding): premultiplied BGRA
/// pixels where the server's bitmask is set, transparent elsewhere.
public struct VNCCursor: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var hotspotX: Int
    public var hotspotY: Int
    /// `width * height` words, `0xAARRGGBB`.
    public var pixels: [UInt32]

    public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, pixels: [UInt32]) {
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixels = pixels
    }

    public var isEmpty: Bool { width == 0 || height == 0 }

    public func makeImage() -> CGImage? {
        guard !isEmpty else { return nil }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
