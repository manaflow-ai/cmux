public import AppKit
import CCmuxMotionFFI
import CmuxNextWakeups

/// The wallpaper as a light source (`appearance.wallpaperLighting`; Leo 2026-11-17: "what if you
/// almost treat the background wallpaper like a light source? lighting inside cmux!?").
///
/// cmux-motion's light field (`light.rs`, through `cmux_motion_light_*`) reads a picture once,
/// off the main actor (the desktop's sample in ``DesktopWallpaperWatch``, a theme picture's decode
/// in ``BackdropImageStore``), and finds its key light, colors and strengths, in linear light.
/// Nothing here runs per frame: the field changes with the picture, a page's style with the field
/// or the key window's place on its screen, and a native rim (``WallpaperRimLayer``) with the field
/// or its view's layout.
///
/// ```swift
/// let field = WallpaperLightField.read(image)
/// let style = field?.style(window: window.frame, screen: screen.frame)
/// ```
public nonisolated struct WallpaperLightField: Equatable, Sendable {
    /// `CmuxLightField`'s values, kept in Swift tuples of doubles and copied back for each call.
    private let parts: Parts
    /// The picture's width over its height (where the key light falls on an aspect-filled screen).
    public let aspect: Double

    /// The light field of `image`, drawn into a 64-pixel-long bitmap first (the size the watch decodes);
    /// nil for an empty or fully transparent picture. The draw converts the picture's own color space
    /// (Display P3, an embedded profile) to sRGB, which the field decodes to linear light.
    public static func read(_ image: CGImage) -> WallpaperLightField? {
        guard image.width > 0, image.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let long = 64
        let width = image.width >= image.height ? long : max(1, long * image.width / image.height)
        let height = image.width >= image.height ? max(1, long * image.height / image.width) : long
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var field = CmuxLightField()
        // A bitmap context's first row in memory is the image's top, as the field reads it.
        let ok = bytes.withUnsafeBufferPointer { pixels in
            cmux_motion_light_field(pixels.baseAddress, pixels.count, UInt32(width), UInt32(height), UInt32(width * 4), &field)
        }
        guard ok else { return nil }
        return WallpaperLightField(parts: Parts(field), aspect: Double(image.width) / Double(image.height))
    }

    /// The rim, bloom and tint colors, sRGB 0...1.
    public var rim: (red: Double, green: Double, blue: Double) { parts.rim }
    public var bloom: (red: Double, green: Double, blue: Double) { parts.bloom }
    public var tint: (red: Double, green: Double, blue: Double) { parts.tint }
    /// The key light's place in the picture (0...1 from the top left) and strength, 0...1.
    public var key: (x: Double, y: Double, strength: Double) { (parts.keyX, parts.keyY, parts.keyStrength) }

    /// What a page's glass draws from the light, for a window at `window` on a `screen` whose
    /// desktop picture this field is (both in AppKit screen coordinates). With `screen` nil, the
    /// picture fills the window itself (a theme's art).
    public func style(window: CGRect, screen: CGRect?) -> Style? {
        guard let geometry = Geometry(rect: window, container: screen ?? window, field: self) else { return nil }
        var rect = [geometry.rect.minX, geometry.rect.minY, geometry.rect.width, geometry.rect.height].map(Double.init)
        var out = CmuxLightStyle()
        var raw = parts.raw
        guard cmux_motion_light_style(&raw, geometry.light.x, geometry.light.y, &rect, geometry.diagonal, &out) else { return nil }
        return Style(dx: out.dx, dy: out.dy, rimAlpha: out.rim_alpha, bloomAlpha: out.bloom_alpha, tintShare: out.tint_share)
    }

    /// The rim light of a view at `rect` in a window whose art this field is (`container` is the
    /// window or, for the desktop picture, the screen; all in screen coordinates).
    public func rim(rect: CGRect, container: CGRect) -> Rim? {
        guard let geometry = Geometry(rect: rect, container: container, field: self) else { return nil }
        var flat = [geometry.rect.minX, geometry.rect.minY, geometry.rect.width, geometry.rect.height].map(Double.init)
        var out = CmuxLightRim()
        var raw = parts.raw
        guard cmux_motion_light_rim(&raw, geometry.light.x, geometry.light.y, &flat, geometry.diagonal, &out) else { return nil }
        return Rim(center: CGPoint(x: out.center_x, y: out.center_y), radius: CGSize(width: out.radius_x, height: out.radius_y),
                   alpha: out.alpha)
    }

    public static func == (lhs: WallpaperLightField, rhs: WallpaperLightField) -> Bool {
        lhs.aspect == rhs.aspect && lhs.rim == rhs.rim && lhs.bloom == rhs.bloom && lhs.tint == rhs.tint && lhs.key == rhs.key
            && lhs.parts.keySpread == rhs.parts.keySpread && lhs.parts.ambientLuminance == rhs.parts.ambientLuminance
    }

    /// `cmux_motion_light_style`'s answer.
    public struct Style: Equatable, Sendable {
        public let dx: Double
        public let dy: Double
        public let rimAlpha: Double
        public let bloomAlpha: Double
        public let tintShare: Double
    }

    /// `cmux_motion_light_rim`'s answer, in the view's unit space, top left origin.
    public struct Rim: Equatable, Sendable {
        public let center: CGPoint
        public let radius: CGSize
        public let alpha: Double
    }

    /// Every field of `CmuxLightField`, the same names and order.
    private struct Parts: Sendable {
        typealias RGB = (Double, Double, Double)
        let ambient: RGB
        let ambientLuminance: Double
        let key: RGB
        let keyX: Double
        let keyY: Double
        let keyStrength: Double
        let keySpread: Double
        let dominant: (RGB, RGB, RGB, RGB)
        let dominantWeight: (Double, Double, Double, Double)
        let dominantCount: UInt32
        let rim: RGB
        let bloom: RGB
        let tint: RGB

        init(_ raw: CmuxLightField) {
            ambient = raw.ambient
            ambientLuminance = raw.ambient_luminance
            key = raw.key
            keyX = raw.key_x
            keyY = raw.key_y
            keyStrength = raw.key_strength
            keySpread = raw.key_spread
            dominant = raw.dominant
            dominantWeight = raw.dominant_weight
            dominantCount = raw.dominant_count
            rim = raw.rim
            bloom = raw.bloom
            tint = raw.tint
        }

        var raw: CmuxLightField {
            CmuxLightField(ambient: ambient, ambient_luminance: ambientLuminance, key: key, key_x: keyX, key_y: keyY,
                           key_strength: keyStrength, key_spread: keySpread, dominant: dominant, dominant_weight: dominantWeight,
                           dominant_count: dominantCount, rim: rim, bloom: bloom, tint: tint)
        }
    }

    /// A rectangle and the key light in its container's points from the container's top left.
    private struct Geometry {
        let rect: CGRect
        let light: (x: Double, y: Double)
        let diagonal: Double

        init?(rect screenRect: CGRect, container: CGRect, field: WallpaperLightField) {
            guard container.width > 0, container.height > 0 else { return nil }
            // AppKit screen coordinates grow upward; the field's grow down from the top left.
            rect = CGRect(x: screenRect.minX - container.minX, y: container.maxY - screenRect.maxY,
                          width: screenRect.width, height: screenRect.height)
            var point = [0.0, 0.0]
            var raw = field.parts.raw
            guard cmux_motion_light_point(&raw, field.aspect, container.width, container.height, &point) else { return nil }
            light = (point[0], point[1])
            diagonal = (container.width * container.width + container.height * container.height).squareRoot()
        }
    }
}

/// The light every page and rim reads now: the desktop picture's field while the setting is on and
/// the window shows the desktop, the theme art's field while it shows art, and the key window's
/// place for the pages' direction. One change repaints the pages once and tells each rim layer
/// once; nothing polls. The app's is ``BackdropImageStore/light``.
@MainActor
public final class WallpaperLight {
    /// `appearance.wallpaperLighting`. While on, the light follows the key window's moves.
    public var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            changed()
        }
    }
    /// The desktop picture's field (``DesktopWallpaperWatch``).
    public private(set) var desktop: WallpaperLightField?
    /// The style the pages draw: the key window's.
    public private(set) var pageStyle: (field: WallpaperLightField, style: WallpaperLightField.Style)?
    /// Repaints every page after a change; by default the app's theme (`ThemeScope.app`).
    private let repaint: @MainActor () -> Void
    private let rims = NSHashTable<WallpaperRimLayer>.weakObjects()
    private let settle = DemandTimer(owner: "wallpaper-light-window-move")

    init(repaint: @escaping @MainActor () -> Void = { ThemeScope.app.store.repaintAll() }) {
        self.repaint = repaint
    }

    /// The desktop picture's field landed (or went: nil).
    func desktopDidChange(_ field: WallpaperLightField?) {
        guard field != desktop else { return }
        desktop = field
        changed()
    }

    /// A window's art changed (a new theme picture, a crossfade landed): the light follows it.
    func artDidChange() {
        guard enabled else { return }
        changed()
    }

    func register(_ rim: WallpaperRimLayer) { rims.add(rim) }

    /// The field lighting `window`: its theme art's when it shows art (the picture fills the
    /// window), else the desktop picture's (it fills the screen), whether the window draws it
    /// (the Desktop Wallpaper background) or lets it through (see-through glass).
    func field(for window: NSWindow?) -> (field: WallpaperLightField, screen: CGRect?)? {
        guard enabled else { return nil }
        if let view = window.flatMap(Self.material(of:)), !view.followsDesktop, view.artImage != nil {
            return view.artLight.map { ($0, nil) }
        }
        guard let desktop else { return nil }
        return (desktop, (window?.screen ?? NSScreen.main)?.frame)
    }

    /// The window's own backdrop: the first material view under its content, two levels down at most.
    private static func material(of window: NSWindow) -> WindowMaterialView? {
        guard let content = window.contentView else { return nil }
        if let view = content as? WindowMaterialView { return view }
        for child in content.subviews {
            if let view = child as? WindowMaterialView { return view }
            if let view = child.subviews.first(where: { $0 is WindowMaterialView }) as? WindowMaterialView { return view }
        }
        return nil
    }

    /// One of the app's windows moved, ended a live resize, became key or changed screen (its window
    /// delegate, and ``DesktopWallpaperWatch/windowDidChange()``): the pages' direction is read again
    /// once the move settles (a drag moves it every frame; the light follows at its end, not during it).
    public func windowDidMove() {
        guard enabled else { return }
        settle.schedule(after: .milliseconds(150)) { @MainActor [weak self] in self?.changed() }
    }

    /// The CSS variables a page's glass reads (`webviews` glass.css WALLPAPER LIGHTING); empty while off.
    public var cssVariables: [String: String] {
        guard let (field, style) = pageStyle else { return [:] }
        // CSS `color(srgb ...)`: the field's colors are sRGB, tagged so.
        func color(_ c: (red: Double, green: Double, blue: Double)) -> String {
            "color(srgb \(number(min(max(c.red, 0), 1))) \(number(min(max(c.green, 0), 1))) \(number(min(max(c.blue, 0), 1))))"
        }
        func number(_ v: Double) -> String { String(format: "%.3f", v) }
        return ["--wl-dx": number(style.dx), "--wl-dy": number(style.dy),
                "--wl-rim": color(field.rim), "--wl-rim-alpha": number(style.rimAlpha),
                "--wl-bloom": color(field.bloom), "--wl-bloom-alpha": number(style.bloomAlpha),
                "--wl-tint": color(field.tint), "--wl-tint-share": number(style.tintShare)]
    }

    private func changed() {
        let window = NSApp?.keyWindow ?? NSApp?.mainWindow
        let next = field(for: window).flatMap { lit -> (WallpaperLightField, WallpaperLightField.Style)? in
            guard let window, let style = lit.field.style(window: window.frame, screen: lit.screen) else { return nil }
            return (lit.field, style)
        }
        let differs = next?.0 != pageStyle?.field || next?.1 != pageStyle?.style
        pageStyle = next
        for rim in rims.allObjects { rim.lightDidChange() }
        if differs { repaint() }
    }
}
