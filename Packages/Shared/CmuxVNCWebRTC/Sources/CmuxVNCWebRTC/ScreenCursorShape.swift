import CoreGraphics
import Foundation
import ImageIO

/// Host → viewer `cursor` (``ScreenHostMessage/cursorShapeType``): the Mac's
/// own cursor image, the one macOS shows (arrow, I-beam, hand, resize, an
/// app's custom cursor), so a viewer that draws pointers draws exactly that
/// shape instead of one of its own. Sent once per shape, before the
/// telepointers that name it (``ScreenHostMessage/shape``), to a viewer that
/// said ``ScreenHostMessage/cursorShapeCapability``.
///
/// Sizes are fractions of the streamed display, so the viewer draws the
/// cursor exactly as large as the Mac shows it at any zoom; the hotspot is a
/// fraction of the cursor's own size. The image carries no shadow: macOS
/// draws the cursor's shadow itself (``shadow``), and so does the viewer.
public struct ScreenCursorShape: Codable, Sendable, Equatable {
    /// The shape's id (cmux-rd-screen `screen_cursor_shape`: FNV-1a 64 over its PNG and hotspot): equal images share it.
    public var id: String
    /// The image as base64 PNG (straight alpha), at most ``maxSide`` pixels a side.
    public var png: String
    /// Width and height as fractions of the streamed display.
    public var w: Double
    public var h: Double
    /// The hotspot as a fraction of the cursor's width and height (0–1, top left origin).
    public var hx: Double
    public var hy: Double
    /// The cursor's size in the Mac's points, for its shadow (``shadow``).
    public var pw: Double
    public var ph: Double

    public init(id: String, png: String, w: Double, h: Double, hx: Double, hy: Double, pw: Double, ph: Double) {
        self.id = id
        self.png = png
        self.w = w
        self.h = h
        self.hx = hx
        self.hy = hy
        self.pw = pw
        self.ph = ph
    }

    /// The longest side the host sends: a larger cursor (Accessibility's
    /// pointer size) is scaled down to it.
    public static let maxSide = 256

    /// The shadow macOS draws under every cursor, in points: the window
    /// server's cursor plists (HIServices `cursors/*/info.plist`) give black
    /// at 0.45 alpha, blur 2, offset 0, -1 (one point down).
    public static let shadow = (opacity: 0.45, blur: 2.0, offsetDown: 1.0)

        for byte in png { mix(byte) }
        for value in [hotspot.x, hotspot.y] {
            withUnsafeBytes(of: Double(value).bitPattern.littleEndian) { $0.forEach(mix) }
        }
        return String(hash, radix: 16)
    }

    /// Whether the sizes and hotspot are ones a viewer can draw.
    public var isDrawable: Bool {
        let fractions = [w, h]
        let hotspot = [hx, hy]
        return fractions.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 1 }
            && hotspot.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
            && pw.isFinite && ph.isFinite && pw > 0 && ph > 0
    }

    /// The decoded image; nil for a shape a viewer can't draw (bad sizes,
    /// not a PNG, larger than ``maxSide``).
    public func image() -> CGImage? {
        guard isDrawable, let data = Data(base64Encoded: png),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, image.width <= Self.maxSide, image.height <= Self.maxSide
        else { return nil }
        return image
    }
}
