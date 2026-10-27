public import AppKit
import CmuxNextDesign

/// The sidebar's profile control (SIDEBAR-FOOTER-AND-SPACE-MENU amendment
/// 2): the current profile's initial (signed in: the cmux user's picture,
/// else their initials) in a `SidebarStyle.avatarDiameter` circle, centered in
/// the square item. The avatar alone opens the menu, as browser profile
/// buttons do. It draws inside a `SidebarItemRowView`, which owns the hover
/// pill, the click and accessibility.
final class SidebarAvatarView: NSView {
    var avatar: SidebarAvatar? {
        didSet {
            guard avatar != oldValue else { return }
            if avatar?.imageData != oldValue?.imageData { pictureImage = Self.picture(avatar).flatMap(Self.cgImage) }
            needsDisplay = true // invalidate: another avatar (the guard above)
        }
    }
    /// Full strength under the pointer or keyboard focus, secondary at rest
    /// (the same rule as the sidebar's other icon items).
    var isStrong = false { didSet { if isStrong != oldValue { needsDisplay = true } } }

    /// The disc (glass fill and rim), the picture, its glaze and the initial: layer properties and a
    /// glyph layer, so a hover's strength change or a theme change draws no pixels.
    let disc = ChromeFillLayer()
    let picture = ChromeFillLayer()
    private let glaze = CAGradientLayer()
    let initial = ChromeTextLayer()
    /// The avatar's picture, decoded once per image (nil: the initial shows).
    private var pictureImage: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        disc.masksToBounds = true
        disc.isHidden = true
        glaze.actions = Self.still
        glaze.colors = [NSColor.white.withAlphaComponent(0.3).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        glaze.locations = [0, 0.6]
        // The view is flipped: y 0 is the disc's top, where the light falls.
        glaze.startPoint = CGPoint(x: 0.5, y: 0)
        glaze.endPoint = CGPoint(x: 0.5, y: 1)
        initial.actions = Self.still
        initial.isHidden = true
        disc.addSublayer(picture)
        disc.addSublayer(glaze)
        layer?.addSublayer(disc)
        layer?.addSublayer(initial)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The gradient's and glyph layer's own keys that the avatar changes: all still.
    private static let still: [String: any CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(), "contentsScale": NSNull(),
        "hidden": NSNull(), "colors": NSNull(), "opacity": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The circle, in this view's coordinates: centered in the square item,
    /// where the row's hover pill and click area sit.
    var circleFrame: NSRect {
        let d = SidebarStyle.avatarDiameter
        return NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
    }

    /// The avatar's picture, decoded; nil draws the initial.
    static func picture(_ avatar: SidebarAvatar?) -> NSImage? {
        avatar?.imageData.flatMap(NSImage.init(data:)).flatMap { $0.isValid ? $0 : nil }
    }

    private static func cgImage(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    /// The avatar ``draw(_:in:strong:)`` paints, as layers: the picture clipped round, else the glass
    /// disc with its glaze and the initial; the rim on both (a border draws over the sublayers).
    override func updateLayer() {
        guard let avatar else {
            disc.isHidden = true
            initial.isHidden = true
            return
        }
        let circle = circleFrame
        let scale = window?.backingScaleFactor ?? 2
        let strong = isStrong
        let image = pictureImage
        disc.frame = circle
        disc.cornerRadius = circle.height / 2
        disc.borderWidth = Metrics.lineWidth(1) / max(scale, 1)
        picture.frame = CGRect(origin: .zero, size: circle.size)
        picture.contentsScale = scale
        picture.contents = image
        picture.opacity = strong ? 1 : 0.85
        picture.isHidden = image == nil
        glaze.frame = picture.frame
        glaze.isHidden = image != nil
        initial.isHidden = image != nil
        performWithTheme {
            disc.borderColor = Palette.textPrimary.withAlphaComponent(0.18).cgColor
            // Glass, never opaque: the disc lets the sidebar through a little, more at rest.
            let fill = avatar.color.map { SidebarStyle.color($0) } ?? Palette.accentFill
            disc.backgroundColor = image == nil ? fill.withAlphaComponent(strong ? 0.94 : 0.84).cgColor : nil
            initial.foregroundColor = (avatar.color == nil ? Palette.onAccent : Palette.textOnPrimary).cgColor
        }
        if image == nil { placeInitial(avatar.initial, in: circle, scale: scale) }
        disc.isHidden = false
    }

    /// The initial's glyph layer, its ink in the middle of `circle` (``initialOrigin(_:font:in:flipped:)``).
    private func placeInitial(_ text: String, in circle: NSRect, scale: CGFloat) {
        let font = NSFont.systemFont(ofSize: circle.height * (text.count > 1 ? 0.44 : 0.56), weight: TypeScale.strong)
        initial.font = font
        initial.string = text
        initial.contentsScale = scale
        let origin = Self.initialOrigin(text, font: font, in: circle, flipped: true)
        // The layer puts the baseline `ascender` below its top, as draw(at:) does from `origin`.
        initial.frame = NSRect(x: origin.x, y: origin.y, width: ceil(initial.textWidth) + 2,
                               height: ceil(font.ascender - font.descender) + 1)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize, avatar != nil { needsDisplay = true } // invalidate: the circle centers in the new size
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if avatar != nil { needsDisplay = true } // invalidate: the rim and glyphs follow the new scale
    }

    /// The picture clipped round, else the initial on the profile's color or the theme accent,
    /// glazed like glass (Leo 2026-10-21: "just make it a good icon").
    /// theme-scoped: called from the footer or the menu image renderer.
    static func draw(_ avatar: SidebarAvatar, in circle: NSRect, strong: Bool) {
        if let picture = picture(avatar) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: circle).addClip()
            picture.draw(in: circle, from: .zero, operation: .sourceOver, fraction: strong ? 1 : 0.85, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            drawRim(in: circle)
            return
        }
        // Glass, never opaque: the disc lets the sidebar through a little, more at rest.
        let glass: CGFloat = strong ? 0.94 : 0.84
        let fill = avatar.color.map { SidebarStyle.color($0) } ?? Palette.accentFill
        fill.withAlphaComponent(glass).setFill()
        NSBezierPath(ovalIn: circle).fill()
        drawGlaze(in: circle)
        drawRim(in: circle)
        let text = avatar.color == nil ? Palette.onAccent : Palette.textOnPrimary
        let scale: CGFloat = avatar.initial.count > 1 ? 0.44 : 0.56
        let font = NSFont.systemFont(ofSize: circle.height * scale, weight: TypeScale.strong)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: text]
        avatar.initial.draw(at: initialOrigin(avatar.initial, font: font, in: circle,
                                              flipped: NSGraphicsContext.current?.isFlipped ?? true),
                            withAttributes: attributes)
    }

    /// The glass sheen: light falling on the disc's top half and fading out by its middle.
    private static func drawGlaze(in circle: NSRect) {
        guard let glaze = NSGradient(colorsAndLocations: (NSColor.white.withAlphaComponent(0.3), 0),
                                     (NSColor.white.withAlphaComponent(0), 0.6)) else { return }
        // Angle 90 runs from minY to maxY: the top in a flipped view, the bottom in a bitmap.
        let flipped = NSGraphicsContext.current?.isFlipped ?? true
        glaze.draw(in: NSBezierPath(ovalIn: circle), angle: flipped ? 90 : -90)
    }

    /// The glass rim: a hairline just inside the edge, so the disc reads crisp on any backdrop.
    private static func drawRim(in circle: NSRect) {
        let width = Metrics.lineWidth(1) / max(NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform.a ?? 2, 1)
        guard width > 0 else { return }
        let rim = NSBezierPath(ovalIn: circle.insetBy(dx: width / 2, dy: width / 2))
        rim.lineWidth = width
        Palette.textPrimary.withAlphaComponent(0.18).setStroke()
        rim.stroke()
    }

    /// Where `initial` draws so its ink sits in the middle of `circle` (Leo 2026-10-20: the "L"
    /// sat off center): the glyphs' ink box across, the capital letters' height down, not the
    /// line box with its leading, descender and side bearings.
    static func initialOrigin(_ initial: String, font: NSFont, in circle: NSRect, flipped: Bool) -> NSPoint {
        let ink = (initial as NSString).boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesDeviceMetrics],
                                                     attributes: [.font: font])
        let x = circle.midX - ink.midX
        // draw(at:) puts the line box's top (flipped) or bottom at y; the baseline sits
        // `ascender` below the top, or `-descender` above the bottom.
        let baseline = flipped ? circle.midY + font.capHeight / 2 : circle.midY - font.capHeight / 2
        let y = flipped ? baseline - font.ascender : baseline + font.descender
        return NSPoint(x: x, y: y)
    }
}

extension SidebarAvatar {
    /// Render the avatar as the image in the profile menu's current-profile row.
    @MainActor public func image(diameter: Double) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(diameter * 2), pixelsHigh: Int(diameter * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        ThemeScope.app.perform { SidebarAvatarView.draw(self, in: NSRect(origin: .zero, size: size), strong: true) }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }
}
