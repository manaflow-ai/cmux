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
        var role: SurfaceRole
        var rect: CGRect
        var radius: CGFloat
        var opacity: CGFloat
    }

    private var views: [String: (role: SurfaceRole, level: GlassLevel, view: OverlaySurfaceView)] = [:]
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
                let view = Glass.makeSurface(surface.role, interactive: false)
                view.tintLevel = Glass.hostTintLevel(surface.level)
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

/// A surface's two lines, in the type the web cells draw (the body size, 13 pt on 18 pt lines, 8 pt from
/// the top and 12 pt from the left: `--ds-space-2` and `--ds-space-3`), primary then secondary ink.
final class GlassParityTextView: NSView {
    init(frame: NSRect, title: String, detail: String) {
        super.init(frame: frame)
        for (index, (text, color)) in [(title, Palette.textPrimary), (detail, Palette.textSecondary)].enumerated() {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: TypeScale.body)
            label.textColor = color
            label.frame = CGRect(x: 12, y: 8 + CGFloat(index) * 18, width: frame.width - 24, height: 18)
            label.autoresizingMask = [.width]
            addSubview(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
