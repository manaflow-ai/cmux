import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A window frame from the helper is a JPEG, which has no alpha: the window's rounded corners,
/// transparent on screen, come out black, and the preview card showed a black box around the app.
/// This finds those black corners and clears them, so the card shows the window's own shape.
nonisolated struct ComputerUseFrameCorners {
    /// A corner pixel with every channel at or under this counts as the capture's empty corner.
    static let blackLevel: UInt8 = 16
    /// The black run along a corner's diagonal is `radius * (1 - 1/sqrt 2)` long.
    static let diagonalToRadius = 1 / (1 - 1 / 2.0.squareRoot())

    private let width: Int
    private let height: Int
    private let pixels: [UInt8]

    /// The decoded frame as 8-bit RGBA, or nil when it cannot be read.
    init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(image)
    }

    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = Self.context(buffer.baseAddress, width: width, height: height) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The window's corner radius in pixels, read from the black runs on the four corners'
    /// diagonals. Nil when fewer than two corners are black, as in a screen capture, or when every
    /// black run is longer than a window corner can be, as in an app whose own edge is black.
    /// Nil for a frame too small to walk a diagonal `limit` pixels long.
    func radius() -> CGFloat? {
        let limit = max(2, min(width, height) / 8)
        guard min(width, height) > limit else { return nil }
        let corners = [(0, 0, 1, 1), (width - 1, 0, -1, 1), (0, height - 1, 1, -1), (width - 1, height - 1, -1, -1)]
        let runs = corners.map { x, y, dx, dy in blackRun(x: x, y: y, dx: dx, dy: dy, limit: limit) }
            .filter { $0 >= 2 && $0 < limit }
        guard runs.count >= 2, let shortest = runs.min() else { return nil }
        return CGFloat(shortest) * Self.diagonalToRadius
    }

    /// The frame as a PNG with its corners cleared on the window's rounded outline.
    func rounded(radius: CGFloat) -> Data? {
        guard let image = image() else { return nil }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let clipped = out.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = Self.context(buffer.baseAddress, width: width, height: height) else { return nil }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let corner = min(radius, CGFloat(min(width, height)) / 2)
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: corner, cornerHeight: corner, transform: nil))
            context.clip()
            context.draw(image, in: bounds)
            return context.makeImage()
        }
        guard let clipped else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, clipped, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// `data` with its black window corners cleared, as a PNG, or nil when it has none to clear.
    static func clearingCorners(_ data: Data) -> Data? {
        guard let frame = ComputerUseFrameCorners(data), let radius = frame.radius() else { return nil }
        return frame.rounded(radius: radius)
    }

    /// The pixel's alpha (tests read the cleared corners through it).
    func alpha(x: Int, y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }

    private func blackRun(x: Int, y: Int, dx: Int, dy: Int, limit: Int) -> Int {
        var step = 0
        while step < limit, isBlack(x: x + step * dx, y: y + step * dy) { step += 1 }
        return step
    }

    private func isBlack(x: Int, y: Int) -> Bool {
        let index = (y * width + x) * 4
        return pixels[index] <= Self.blackLevel && pixels[index + 1] <= Self.blackLevel && pixels[index + 2] <= Self.blackLevel
    }

    private func image() -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { buffer in
            Self.context(buffer.baseAddress, width: width, height: height)?.makeImage()
        }
    }

    private static func context(_ base: UnsafeMutableRawPointer?, width: Int, height: Int) -> CGContext? {
        CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
