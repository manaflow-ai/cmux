#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
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
    static let lineHeight: CGFloat = 18
    static let origin = CGPoint(x: 12, y: 8)

    init(frame: NSRect, title: String, detail: String) {
        lines = [(title, Palette.textPrimary), (detail, Palette.textSecondary)]
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
        let font = NSFont.systemFont(ofSize: TypeScale.body)
        let halfLeading = (Self.lineHeight - (font.ascender - font.descender)) / 2
        for (index, (text, color)) in lines.enumerated() {
            let top = Self.origin.y + CGFloat(index) * Self.lineHeight + halfLeading
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                .draw(at: CGPoint(x: Self.origin.x, y: top))
        }
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
