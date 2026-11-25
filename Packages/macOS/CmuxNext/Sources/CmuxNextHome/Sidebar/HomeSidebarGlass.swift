import AppKit
import QuartzCore

/// The Home list panel's glass, as Messages draws its sidebar on macOS 26 (measured from the user's
/// screen recording at 2x on 2026-11-23: "copy it 1:1 and also pay attention to the glow and where
/// its at (its from the top, not from the side)"). In dark: the window's own grey, a blue light from
/// above that fades out over 380 pt, and a one-pixel rim lit blue along the top and down the upper
/// left, grey elsewhere. No shadow. Light keeps a white wash and a white rim. Pure colours from the
/// surface, the window's cover and the appearance; the views apply them.
nonisolated struct HomeSidebarGlass: Equatable {
    var dark: Bool
    /// The panel's fill: black at 5 % (dark) or 5.92 % (light) over the column's own fill. Over an opaque window
    /// that is the surface 5 % toward black (Messages' panel is a level or two under the window); over a
    /// translucent window it blends with the desktop or the picture as the rest of the window does. An opaque
    /// tint hid the window's transparency (the user, 2026-11-23: "the background needs to blend on low
    /// opacity/transprency"). Under ``legibleCover`` the surface tops the cover up first, so the list's text
    /// stays readable over a white desktop or a busy picture ("being able to read them").
    var tint: NSColor
    /// The least the panel covers what is behind the window (0...1): about the workspace sidebar's cover beside it
    /// (0.71 at a 0.5 window), so the two sidebars read as one; 0.8 read too dark (the user, 2026-11-24). Over a
    /// white desktop in dark the name reads at 7.1:1 and the preview's grey at 3.9:1 (2.1:1 at the window's 0.5).
    static let legibleCover = 0.7
    /// The wash from the top edge down: a colour and its distance from the top, in points.
    var wash: [(at: CGFloat, color: CGColor)]
    /// The rim from top to bottom: a colour and its distance from the top, in points
    /// (`.infinity`: the bottom edge).
    var rim: [(at: CGFloat, color: CGColor)]
    /// The upper left's blue on the rim (Messages: down to about 170 pt on the left, none on the right).
    var rimSide: CGColor?
    /// The two shadows' opacities (none in dark, as in Messages).
    var shadowOpacities: (far: Float, near: Float)

    /// The wash's height under the panel's top edge.
    var washBand: CGFloat { wash.last?.at ?? 0 }

    /// - Parameters:
    ///   - surface: The window's colour (its alpha is ignored): what tops a thin cover up.
    ///   - cover: How much the window and the column's fill already cover the desktop under the panel (1: opaque).
    init(surface: NSColor, cover: Double, dark: Bool) {
        self.dark = dark
        // Light: the surface 8 % toward black at 74 %, the same as black at 0.74 x 0.08 over the surface.
        let shade: CGFloat = dark ? 0.05 : 0.0592
        // The surface at `top`, so that with the cover under it the panel covers `legibleCover`; then the shade.
        let under = min(max(cover, 0), 1)
        let top = CGFloat(under >= Self.legibleCover ? 0 : (Self.legibleCover - under) / (1 - under))
        let base = surface.usingColorSpace(.sRGB) ?? surface
        let alpha = 1 - (1 - shade) * (1 - top)
        func channel(_ c: CGFloat) -> CGFloat { (1 - shade) * top * c / alpha }
        tint = NSColor(srgbRed: channel(base.redComponent), green: channel(base.greenComponent), blue: channel(base.blueComponent), alpha: alpha) // colour-allow: the theme's own window colour under the shade, at the cover it needs; no new colour
        if dark {
            // Messages: 24 grey under the light, 20 33 44 at the top (blue 0 96 196 at 12.5 %), eased
            // out. On cmux's darker grey that read as too much (the user, 2026-11-23): 7 % at the top.
            let blue = NSColor(srgbRed: 0, green: 96 / 255, blue: 196 / 255, alpha: 1) // colour-allow: Messages' measured sidebar light and rim (macOS 26, 2x), the same in every theme; no theme token is this step
            let fade: [(CGFloat, CGFloat)] = [(0, 1), (30, 1), (60, 0.62), (100, 0.45), (140, 0.35), (180, 0.25),
                                               (220, 0.18), (260, 0.12), (340, 0.05), (380, 0)]
            wash = fade.map { ($0.0, blue.withAlphaComponent(0.07 * $0.1).cgColor) }
            // Messages' rim: 28 79 115 along the top, white 15 % on the sides, 12 % at the bottom.
            let lit = NSColor(srgbRed: 36 / 255, green: 125 / 255, blue: 186 / 255, alpha: 0.5) // colour-allow: Messages' measured sidebar light and rim (macOS 26, 2x), the same in every theme; no theme token is this step
            rim = [(0, lit.cgColor), (6, lit.cgColor), (18, NSColor(white: 1, alpha: 0.15).cgColor), // colour-allow: Messages' measured sidebar light and rim (macOS 26, 2x), the same in every theme; no theme token is this step
                   (.infinity, NSColor(white: 1, alpha: 0.12).cgColor)] // colour-allow: Messages' measured sidebar light and rim (macOS 26, 2x), the same in every theme; no theme token is this step
            rimSide = NSColor(srgbRed: 22 / 255, green: 69 / 255, blue: 121 / 255, alpha: 0.4).cgColor // colour-allow: Messages' measured sidebar light and rim (macOS 26, 2x), the same in every theme; no theme token is this step
            shadowOpacities = (0, 0)
        } else {
            let white = NSColor.white
            wash = [(0, 1), (30, 0.62), (60, 0.30), (90, 0.10), (120, 0)].map { ($0.0, white.withAlphaComponent(0.35 * $0.1).cgColor) }
            let reflect = NSColor(white: 0, alpha: 0.09) // colour-allow: Messages' measured sidebar light and rim (macOS 26, 2x), the same in every theme; no theme token is this step
            rim = [(0, NSColor(white: 1, alpha: 0.90).cgColor), (18, reflect.cgColor), // colour-allow: Messages' measured sidebar light and rim (macOS 26, 2x), the same in every theme; no theme token is this step
                   (.infinity, NSColor(white: 0, alpha: 0.07).cgColor)] // colour-allow: Messages' measured sidebar light and rim (macOS 26, 2x), the same in every theme; no theme token is this step
            rimSide = nil
            shadowOpacities = (0.16, 0.08)
        }
    }

    static func == (a: Self, b: Self) -> Bool {
        a.dark == b.dark && a.tint == b.tint && a.wash.elementsEqual(b.wash, by: { $0 == $1 })
            && a.rim.elementsEqual(b.rim, by: { $0 == $1 }) && a.rimSide == b.rimSide && a.shadowOpacities == b.shadowOpacities
    }

    /// CSS `color-mix(in srgb, a p, b)`: premultiplied, so a clear side adds no colour.
    static func mix(_ a: NSColor, _ p: CGFloat, _ b: NSColor) -> NSColor {
        let a = a.usingColorSpace(.sRGB) ?? a, b = b.usingColorSpace(.sRGB) ?? b
        let alpha = a.alphaComponent * p + b.alphaComponent * (1 - p)
        guard alpha > 0 else { return .clear }
        func channel(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            (x * a.alphaComponent * p + y * b.alphaComponent * (1 - p)) / alpha
        }
        return NSColor(srgbRed: channel(a.redComponent, b.redComponent), green: channel(a.greenComponent, b.greenComponent), // colour-allow: a mix of two given colours, no colour of its own
                       blue: channel(a.blueComponent, b.blueComponent), alpha: alpha)
    }

    /// Stops in points from the top as a top-down gradient's colours and locations over `height`.
    static func gradient(_ stops: [(at: CGFloat, color: CGColor)], height: CGFloat) -> (colors: [CGColor], locations: [NSNumber]) {
        let h = max(1, height)
        return (stops.map(\.color), stops.map { NSNumber(value: Double($0.at.isFinite ? min(1, $0.at / h) : 1)) })
    }

    /// The wash, top down, as the views lay it out; its colours come from ``init``.
    @MainActor static func configure(wash: CAGradientLayer) {
        wash.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull()]
        wash.startPoint = CGPoint(x: 0.5, y: 1)
        wash.endPoint = CGPoint(x: 0.5, y: 0)
    }
}

/// The panel's rim, over the list: one device pixel along the panel's rounded edge, in
/// ``HomeSidebarGlass/rim`` from top to bottom, with ``HomeSidebarGlass/rimSide`` over the upper
/// left. Takes no clicks.
final class HomePanelRimView: NSView {
    private let gradient = CAGradientLayer()
    private let side = CAGradientLayer()
    private let stroke = CAShapeLayer()
    private let sideStroke = CAShapeLayer()
    private var glass: HomeSidebarGlass?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let still: [String: any CAAction] = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull(),
                                             "startPoint": NSNull(), "endPoint": NSNull()]
        gradient.actions = still
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        side.actions = still
        side.type = .radial
        side.locations = [0, 0.8, 1]
        for (layer, mask) in [(gradient, stroke), (side, sideStroke)] {
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "lineWidth": NSNull()]
            layer.mask = mask
            self.layer?.addSublayer(layer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ glass: HomeSidebarGlass) {
        self.glass = glass
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pixel = 1 / max(1, window?.backingScaleFactor ?? 2)
        let rect = bounds.insetBy(dx: pixel / 2, dy: pixel / 2)
        guard rect.width > 0, rect.height > 0 else { return }
        // CoreGraphics stops on a corner wider than half the rect: clamp it.
        let r = max(0, min(HomeSidebarView.panelCornerRadius - pixel / 2, rect.width / 2, rect.height / 2))
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        for (layer, mask) in [(gradient, stroke), (side, sideStroke)] {
            layer.frame = bounds
            mask.frame = bounds
            mask.lineWidth = pixel
            mask.path = path
        }
        guard let glass else { return }
        let rim = HomeSidebarGlass.gradient(glass.rim, height: bounds.height)
        gradient.colors = rim.colors
        gradient.locations = rim.locations
        side.isHidden = glass.rimSide == nil
        if let blue = glass.rimSide {
            side.colors = [blue, blue, blue.copy(alpha: 0) ?? blue]
            // An ellipse from the top-left corner: 90 % of the width across, 200 pt down (y up).
            side.startPoint = CGPoint(x: 0, y: 1)
            side.endPoint = CGPoint(x: 0.9, y: 1 - min(1, 200 / max(1, bounds.height)))
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

/// The panel's two soft shadows (CSS `0 10px 28px -12px` and `0 2px 6px -2px` in black), drawn
/// only outside the panel, as a box shadow is: the frost is not fully opaque. Light only (Messages
/// draws none in dark). Takes no clicks.
final class HomePanelShadowView: NSView {
    private let far = CALayer()
    private let near = CALayer()
    private let cutout = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for shadow in [far, near] {
            shadow.shadowColor = NSColor.black.cgColor
            shadow.actions = ["shadowPath": NSNull(), "bounds": NSNull(), "position": NSNull(), "shadowOpacity": NSNull()]
            layer?.addSublayer(shadow)
        }
        // Layer coordinates are y up: a CSS offset down is a negative y.
        far.shadowOffset = CGSize(width: 0, height: -10)
        far.shadowRadius = 14
        near.shadowOffset = CGSize(width: 0, height: -2)
        near.shadowRadius = 3
        cutout.fillRule = .evenOdd
        layer?.mask = cutout
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ glass: HomeSidebarGlass) {
        far.shadowOpacity = glass.shadowOpacities.far
        near.shadowOpacity = glass.shadowOpacities.near
    }

    override func layout() {
        super.layout()
        let r = HomeSidebarView.panelCornerRadius
        func path(_ spread: CGFloat) -> CGPath {
            let rect = bounds.insetBy(dx: -spread, dy: -spread)
            guard rect.width > 0, rect.height > 0 else { return CGMutablePath() }
            // CoreGraphics stops on a corner wider than half the rect: clamp it.
            let radius = max(0, min(r + spread, rect.width / 2, rect.height / 2))
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        for shadow in [far, near] { shadow.frame = bounds }
        far.shadowPath = path(-12)
        near.shadowPath = path(-2)
        // Everything but the panel itself, with room for the blur.
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -60, dy: -60))
        outside.addPath(path(0))
        cutout.frame = bounds
        cutout.path = outside
    }
}
