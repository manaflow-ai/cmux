#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads this Mac's cursor shape for ``ScreenCursorShape``: the image every
/// app sees (`NSCursor.currentSystem`), only when the window server's
/// cursor seed changes (the private `CGSCurrentCursorSeed`, looked up at run
/// time; without it, at most every ``fallbackInterval``). A shape that did
/// not change costs one seed read.
final class ScreenCursorReader {
    /// Between shape reads when the cursor seed is not available.
    static let fallbackInterval: TimeInterval = 0.25

    private typealias SeedFunction = @convention(c) () -> Int32
    /// `CGSCurrentCursorSeed`'s address; `RTLD_DEFAULT` searches the images
    /// already loaded (CoreGraphics is).
    private static let seedAddress: Int? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCurrentCursorSeed")
        .map { Int(bitPattern: $0) }

    /// The window server's cursor seed: it changes with the cursor's shape.
    private static func currentSeed() -> Int32? {
        guard let address = seedAddress, let pointer = UnsafeRawPointer(bitPattern: address) else { return nil }
        return unsafeBitCast(pointer, to: SeedFunction.self)()
    }

    private let rules: ScreenRules
    private var seed: Int32?

    init(rules: ScreenRules) {
        self.rules = rules
    }
    private var display: CGRect?
    private var lastRead: Date?

    /// The cursor's shape for `display` (global points, top left origin)
    /// when it may have changed since the last call, or the display did;
    /// nil otherwise, and when there is no cursor to read.
    func read(display: CGRect) async -> ScreenCursorShape? {
        let seed = Self.currentSeed()
        let due: Bool
        if display != self.display {
            due = true
        } else if let seed {
            due = seed != self.seed
        } else {
            due = lastRead.map { Date().timeIntervalSince($0) >= Self.fallbackInterval } ?? true
        }
        guard due else { return nil }
        self.seed = seed
        self.display = display
        lastRead = Date()
        guard let rendered = await MainActor.run(body: { Self.renderCurrent(on: display) }) else { return nil }
        return Self.shape(rendered, display: display, rules: rules)
    }

    /// The current cursor drawn at the display's pixel scale (main actor: AppKit).
    struct Rendered: Sendable {
        let image: CGImage
        /// Size and hotspot in points.
        let size: CGSize
        let hotspot: CGPoint
    }

    @MainActor static func renderCurrent(on display: CGRect) -> Rendered? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let size = cursor.image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(backingScale(of: display), CGFloat(ScreenCursorShape.maxSide) / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        cursor.image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return Rendered(image: image, size: size, hotspot: cursor.hotSpot)
    }

    /// The backing scale of the screen showing `display` (2 on Retina).
    @MainActor static func backingScale(of display: CGRect) -> CGFloat {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let screen = NSScreen.screens.first { screen in
            // NSScreen frames are bottom left based; `display` is top left based (CGEvent).
            let frame = screen.frame
            return CGRect(x: frame.minX, y: primary - frame.maxY, width: frame.width, height: frame.height).intersects(display)
        }
        return screen?.backingScaleFactor ?? 2
    }

    /// The shape message for a rendered cursor on `display`.
    static func shape(_ rendered: Rendered, display: CGRect, rules: ScreenRules) -> ScreenCursorShape? {
        guard display.width > 0, display.height > 0, let png = pngData(rendered.image) else { return nil }
        struct Request: Encodable { var png: String, hotspotX: Double, hotspotY: Double }
        struct Answer: Decodable { var id: String }
        let encoded = png.base64EncodedString()
        guard let id = rules.ask("screen_cursor_shape", Request(png: encoded, hotspotX: Double(rendered.hotspot.x),
                                                               hotspotY: Double(rendered.hotspot.y)), as: Answer.self)?.id
        else { return nil }
        let size = rendered.size
        let shape = ScreenCursorShape(
            id: id,
            png: encoded,
            w: min(1, size.width / display.width), h: min(1, size.height / display.height),
            hx: min(1, max(0, rendered.hotspot.x / size.width)), hy: min(1, max(0, rendered.hotspot.y / size.height)),
            pw: size.width, ph: size.height)
        return shape.isDrawable ? shape : nil
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
#endif
