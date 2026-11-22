#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CoreText
import CmuxNextDesign
import CmuxNextSettings

/// The page provider of one web column: its layout, its surfaces' boxes, its first paint.
@MainActor
final class GlassParityProvider: PageProvider {
    private weak var playground: GlassParityPlayground?
    private let column: GlassParityPlayground.Column

    init(playground: GlassParityPlayground, column: GlassParityPlayground.Column) {
        self.playground = playground
        self.column = column
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let playground else { throw PageError.unknownOp(op) }
        switch op {
        case "cmux.glass_parity.layout": return playground.layout(for: column)
        case "cmux.glass_parity.surfaces": return try playground.surfaces(params, from: column)
        case "cmux.glass_parity.ready":
            playground.pageReady(column)
            return .null
        default: throw PageError.unknownOp(op)
        }
    }
}

/// The App's glass under one web column (host glass): a surface per reported box, under the page.
@MainActor
final class GlassParityHostLayer: NSView {
    struct Surface: Equatable {
        var id: String
        var level: GlassLevel
        var role: SurfaceRole?
        var rect: CGRect
        var radius: CGFloat
        var opacity: CGFloat
    }

    private var views: [String: (role: SurfaceRole?, level: GlassLevel, view: OverlaySurfaceView)] = [:]
    var count: Int { views.count }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ surfaces: [Surface]) {
        var kept = Set<String>()
        for surface in surfaces {
            kept.insert(surface.id)
            if let old = views[surface.id], old.role != surface.role || old.level != surface.level {
                old.view.removeFromSuperview()
                views[surface.id] = nil
            }
            if views[surface.id] == nil {
                // As the agent pane draws its host glass (AgentPaneView+HostGlass.swift).
                let view = Glass.makeHostSurface(level: surface.level, role: surface.role)
                view.translatesAutoresizingMaskIntoConstraints = true
                addSubview(view)
                views[surface.id] = (surface.role, surface.level, view)
            }
            guard let view = views[surface.id]?.view else { continue }
            if view.frame != surface.rect { view.frame = surface.rect }
            if view.cornerRadius != surface.radius { view.cornerRadius = surface.radius }
            if view.alphaValue != surface.opacity { view.alphaValue = surface.opacity }
        }
        for (id, entry) in views where !kept.contains(id) {
            entry.view.removeFromSuperview()
            views[id] = nil
        }
    }
    /// The App's chip glass (the web tooltip's), for the measure's diagnostics.
    var tooltipSurface: NSView? { views.values.first { $0.level == .chip && $0.role == nil }?.view }
}

/// A view's tree as the measure reports it (class, frame, alpha, layer fill, filters, shadow), so two surfaces
/// that should be the same name where they differ.
@MainActor
func glassParityTree(_ view: NSView, depth: Int = 0) -> JSONValue {
    let layer = view.layer
    var node: [String: JSONValue] = [
        "class": .string(String(describing: type(of: view))),
        "frame": .array([view.frame.minX, view.frame.minY, view.frame.width, view.frame.height].map { .number($0) }),
        "alpha": .number(view.alphaValue), "hidden": .bool(view.isHidden),
        "appearance": .string(view.effectiveAppearance.name.rawValue),
    ]
    if let layer {
        node["bg"] = .string(layer.backgroundColor.map { color in NSColor(cgColor: color)?.usingColorSpace(.sRGB).map { String(describing: $0) } ?? String(describing: color) } ?? "nil")
        node["opacity"] = .number(Double(layer.opacity))
        node["shadow"] = .number(Double(layer.shadowOpacity))
        node["filters"] = .number(Double((layer.filters?.count ?? 0) + (layer.backgroundFilters?.count ?? 0)))
        node["masks"] = .bool(layer.masksToBounds)
    }
    if let tinted = glassParityTint(view) {
        node["tint"] = .string(String(describing: tinted.usingColorSpace(.sRGB) ?? tinted))
    }
    if depth < 4 { node["children"] = .array(view.subviews.map { glassParityTree($0, depth: depth + 1) }) }
    return .object(node)
}

/// The glass tint of VIEW, read through the typed glass APIs (no selector or key lookup that could raise).
@MainActor
private func glassParityTint(_ view: NSView) -> NSColor? {
    if let panel = view as? GlassPanelView { return panel.tintColor }
    if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView { return glass.tintColor }
    return nil
}

final class GlassParityFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A surface's two lines, laid out as the web cells lay them: the body size on 18 pt lines, 8 pt from the
/// top and 12 pt from the left (`--ds-space-2`, `--ds-space-3`), primary then secondary ink. Drawn, not
/// labels: each line's glyphs sit where CSS puts them in its line box (half the leading above the font's
/// ascent), with no text field cell insets.
final class GlassParityTextView: NSView {
    private let lines: [(String, NSColor)]
    private let smoothing: Bool
    static let lineHeight: CGFloat = 18
    static let origin = CGPoint(x: 12, y: 8)

    init(frame: NSRect, title: String, detail: String, smoothing: Bool = true) {
        lines = [(title, Palette.textPrimary), (detail, Palette.textSecondary)]
        self.smoothing = smoothing
        super.init(frame: frame)
    }

    /// The baseline of line `index`, as a CSS line box of ``lineHeight`` places it in WebKit and Chromium:
    /// the font's ascent and descent rounded to whole pixels, the half leading floored. AppKit's fractional
    /// metrics put it at 21.62 pt for the 13 pt system font where both engines put 21 (fleet step e573c84a:
    /// every native line a pixel below the web one).
    static func baseline(line index: Int, ascender: CGFloat, descender: CGFloat) -> CGFloat {
        let ascent = ascender.rounded(), descent = (-descender).rounded()
        let halfLeading = ((lineHeight - ascent - descent) / 2).rounded(.down)
        return origin.y + CGFloat(index) * lineHeight + halfLeading + ascent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let font = NSFont.systemFont(ofSize: TypeScale.body)
        context.setShouldSmoothFonts(smoothing)
        // Core Text at the exact baseline: NSAttributedString.draw(at:) places its own baseline from the
        // typesetter's line metrics and drew every line a pixel below WebKit's whatever top it was given (fleet
        // step e21b4763: the native pixels did not move when the top moved by 0.62 pt).
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // this view is flipped
        for (index, (text, color)) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
            context.textPosition = CGPoint(x: Self.origin.x, y: Self.baseline(line: index, ascender: font.ascender, descender: font.descender))
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

/// The native menu row's highlight in the Liquid Glass Parity playground's menu: what ``PopupRowView``
/// draws for a highlighted row (the theme's hover fill) or a pressed one (its pressed fill), at
/// `row` (flipped, in the menu's points) in the row's corner radius; nothing at rest.
final class GlassParityRowFill: NSView {
    var state: GlassParityPlayground.RowState = .rest {
        didSet { if state != oldValue { needsDisplay = true } }
    }
    private let row: CGRect
    private let radius: CGFloat

    init(frame: NSRect, row: CGRect, radius: CGFloat) {
        self.row = row
        self.radius = radius
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard state != .rest else { return }
        performWithTheme {
            (state == .pressed ? Palette.pressedFill : Palette.hoverFill).setFill()
            NSBezierPath(roundedRect: row, xRadius: radius, yRadius: radius).fill()
        }
    }
}
#endif
