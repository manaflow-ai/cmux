import CCmuxWallpaperFFI
import CoreGraphics
import CoreText
public import Foundation
import ImageIO
import Metal

/// A motion scene running in one backdrop (plans/cmux-next/motion-scenes.md): the Rust scene
/// player (`cmux_wallpaper_scene_*`), which steps the scene's keyframes and physics and packs the
/// 2048-byte Scene block the scene engine reads at fragment buffer 1. One per view (its physics
/// world is the view's), and one per still. Not Sendable: it is used on the thread that made it.
nonisolated final class LiveWallpaperScenePlayer {
    private let handle: OpaquePointer

    /// The Scene block's size in floats, from the library that packs it (`cmux_wallpaper_scene_floats`).
    static let floats = Int(cmux_wallpaper_scene_floats())

    /// First-party wallpaper `index`'s scene; nil when it is not a scene.
    init?(firstParty index: Int) {
        guard let handle = cmux_wallpaper_scene_new_first_party(index) else { return nil }
        self.handle = handle
    }

    deinit {
        cmux_wallpaper_scene_free(handle)
    }

    /// Steps the scene's physics to `now` (the monotonic clock in seconds, `CACurrentMediaTime`, the
    /// pointer's clock) with `frame`'s pointer and button, and writes the Scene block for `frame` (its
    /// keyframes at `frame.time`) into `block`, sized to ``floats`` first. False when the library wrote nothing.
    // perf-hot: 50us scene-evaluate (every drawn motion scene frame, and each pointer event while it rests)
    func evaluate(_ frame: LiveWallpaperFrame, now: Double, into block: inout [Float]) -> Bool {
        if block.count != Self.floats { block = [Float](repeating: 0, count: Self.floats) }
        var input = frame.input()
        return block.withUnsafeMutableBufferPointer { out in
            withUnsafePointer(to: &input) { cmux_wallpaper_scene_evaluate(handle, $0, now, out.baseAddress, out.count) }
        }
    }

    /// Nothing on screen changes without input: no keyframes, and the physics, if any, asleep.
    /// The scheduler's `at_rest`.
    var atRest: Bool { cmux_wallpaper_scene_at_rest(handle) }

    /// The scene shows the image slot (the badge: the person's avatar and name).
    var hasImage: Bool { cmux_wallpaper_scene_has_image(handle) }

    /// The scene engine program in Metal Shading Language (`cmux_wallpaper_scene_engine_msl`): the
    /// one program every scene draws with; nil when the library carries none.
    static let engineSource: String? = {
        var length = 0
        guard let bytes = cmux_wallpaper_scene_engine_msl(&length), length > 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
    }()
}

/// What a scene frame binds besides the Frame uniform: the Scene block (fragment buffer 1) and
/// the image slot (fragment texture 0; ``LiveWallpaperGPU/sceneClear`` when there is none).
nonisolated struct LiveWallpaperSceneInputs: Sendable {
    var block: [Float]
    var image: LiveWallpaperSceneImage?
}

/// An image for a scene's image slot, as pixels: BGRA, premultiplied, sRGB-encoded, rows top first.
/// Plain values, so it crosses threads as it is; its texture is made where a frame is encoded (a
/// view's renderer uploads it once per image, ``LiveWallpaperRenderer``; a still uploads its own).
nonisolated struct LiveWallpaperSceneImage: Sendable {
    /// Tells two images apart without comparing their pixels: a renderer uploads only a new one.
    let id = UUID()
    let pixels: [UInt8]
    let width: Int
    let height: Int

    /// Nil when `pixels` do not fill `width` x `height`.
    init?(pixels: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        self.pixels = pixels
        self.width = width
        self.height = height
    }
}

nonisolated extension LiveWallpaperSceneImage {
    /// The pixel format of scene images: BGRA, premultiplied, sRGB-encoded, so the engine samples
    /// linear light like every other color it gets.
    static let pixelFormat = MTLPixelFormat.bgra8Unorm_srgb

    /// The image as a texture the engine samples.
    func texture(device: any MTLDevice) -> (any MTLTexture)? {
        Self.texture(pixels: pixels, width: width, height: height, device: device)
    }

    /// `pixels` (BGRA, premultiplied, `width` x `height`, rows top first) as a texture the engine samples.
    static func texture(pixels: [UInt8], width: Int, height: Int, device: any MTLDevice) -> (any MTLTexture)? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: base, bytesPerRow: width * 4)
        }
        return texture
    }

    /// `image` drawn into premultiplied sRGB BGRA pixels of its size.
    init?(_ image: CGImage) {
        let (width, height) = (image.width, image.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(pixels: pixels, width: width, height: height)
    }
}

/// Who the badge shows (the scene image slot `badge`): a name and, when there is one, a picture.
/// The app sets the signed-in account's on ``BackdropLiveView/badgeIdentity``; without one it is this
/// Mac's user (``macUser``), with initials in an accent circle.
public nonisolated struct LiveWallpaperBadgeIdentity: Sendable, Hashable {
    public var name: String
    /// An encoded picture (PNG, JPEG, ...); nil draws initials.
    public var imageData: Data?

    public init(name: String, imageData: Data? = nil) {
        self.name = name
        self.imageData = imageData
    }

    /// This Mac's user: the full name, else the account name, and no picture.
    public static var macUser: LiveWallpaperBadgeIdentity {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return LiveWallpaperBadgeIdentity(name: full.isEmpty ? NSUserName() : full)
    }

    /// Up to two initials: the first letters of the first and last words.
    var initials: String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return letters.map { String($0).uppercased() }.joined()
    }

    /// A key for a badge drawn for this identity.
    var key: String { "\(name)|\(imageData?.count ?? 0)|\(imageData?.hashValue ?? 0)" }
}

/// The badge a scene's image slot shows: the person's picture (or initials in an accent circle) above
/// their name, drawn off the main thread and uploaded once as a texture.
nonisolated struct LiveWallpaperBadge: Sendable {
    var identity: LiveWallpaperBadgeIdentity
    var colors: LiveWallpaperColors

    /// The badge's pixels: a card of 5 by 7, the hanging card's proportions in the first-party scenes.
    static let width = 480
    static let height = 672

    /// The badge as the scene image's pixels, drawn off the main thread; nil when it does not draw.
    /// The renderer that binds it makes its texture.
    @concurrent
    func sceneImage() async -> LiveWallpaperSceneImage? {
        image().flatMap { LiveWallpaperSceneImage($0) }
    }

    /// The badge drawn at ``width`` x ``height`` pixels, transparent around the picture and the name
    /// (the card behind it is the scene's own shape). CoreGraphics and CoreText only, so any thread.
    /// Nil when CoreGraphics cannot make the bitmap or one of the theme's colors.
    func image() -> CGImage? {
        let (width, height) = (Self.width, Self.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let linear = CGColorSpace(name: CGColorSpace.linearSRGB),
              let accent = Self.color(colors.accent, in: linear), let paper = Self.color(colors.paper, in: linear),
              let ink = Self.color(colors.ink, in: linear),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        // Top-left origin, as the card reads.
        context.translateBy(x: 0, y: h)
        context.scaleBy(x: 1, y: -1)
        let diameter = w * 0.56
        let circle = CGRect(x: (w - diameter) / 2, y: h * 0.16, width: diameter, height: diameter)
        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        if let picture = picture() {
            // Aspect fill into the circle; CoreGraphics draws bottom-up, so flip back for the picture.
            let scale = max(diameter / CGFloat(picture.width), diameter / CGFloat(picture.height))
            let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
            context.translateBy(x: circle.midX, y: circle.midY)
            context.scaleBy(x: 1, y: -1)
            context.draw(picture, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        } else {
            context.setFillColor(accent)
            context.fill(circle)
            // The badge's own pixel scale over the type scale's points: 4 px per point.
            let monogram = Self.font(size: TypeScale.Base.heading * 4.4, bold: true)
            draw(identity.initials, font: monogram, color: paper, centeredAt: CGPoint(x: circle.midX, y: circle.midY),
                 maxWidth: diameter * 0.9, in: context)
        }
        context.restoreGState()
        let nameFont = Self.font(size: TypeScale.Base.heading * 2.2, bold: true)
        draw(identity.name, font: nameFont, color: ink, centeredAt: CGPoint(x: w / 2, y: circle.maxY + h * 0.14),
             maxWidth: w * 0.86, in: context)
        return context.makeImage()
    }

    /// A theme color (linear light) in `linear`; CoreGraphics converts it to the bitmap's sRGB.
    private static func color(_ c: SIMD3<Float>, in linear: CGColorSpace) -> CGColor? {
        CGColor(colorSpace: linear, components: [CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), 1])
    }

    /// The identity's picture, decoded; nil without one or when it does not decode.
    private func picture() -> CGImage? {
        guard let data = identity.imageData, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The system UI font at `size` pixels (CoreText: safe off the main thread).
    private static func font(size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// One line of `text`, truncated with an ellipsis to `maxWidth`, centered on `center` in a
    /// top-left-origin `context`.
    private func draw(_ text: String, font: CTFont, color: CGColor, centeredAt center: CGPoint, maxWidth: CGFloat, in context: CGContext) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
        let line = CTLineCreateTruncatedLine(full, Double(maxWidth), .end, ellipsis) ?? full
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        context.saveGState()
        // CoreText draws bottom-up: flip about the line's baseline.
        context.translateBy(x: center.x - width / 2, y: center.y + (ascent - descent) / 2)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
