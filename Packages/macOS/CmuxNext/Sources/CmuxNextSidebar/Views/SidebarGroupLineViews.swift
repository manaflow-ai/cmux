import AppKit
import CmuxNextDesign
import Observation

/// Each open group's members' line (cx-qno.17, cx-q5jw) as one view under
/// the rows. The lines move on the rows' own springs (`RowMotion.animate`:
/// the render server's `.move` spring, from the rows' begin time), so a
/// line's end tracks its group's last row in every frame and never runs past
/// it (cx-ai79); a spring of another kind beside the rows' drifted apart
/// from them.
@MainActor
final class SidebarGroupLineViews {
    /// One update's motion (`update`): the AppKit changes (fades, or every change without motion), the views
    /// to remove when the move ends, and the frames to move on the render server's spring.
    typealias LineMotion = (changes: () -> Void, leaving: [NSView], springs: [(NSView, NSRect)])

    private var views: [GroupID: GroupLineView] = [:]
    /// The lines the last `update` showed (a group's fold moves them without a pass over every row).
    private(set) var lines: [SidebarGroupLine] = []
    /// Lines of closed or gone groups while they shrink and fade out.
    private var leavingViews: [NSView] = []

    /// Each shown line (not one fading out) by group: its frame and opacity.
    var shown: [GroupID: (frame: CGRect, alpha: CGFloat)] {
        views.compactMapValues { $0.superview == nil ? nil : ($0.frame, $0.alphaValue) }
    }

    /// The changes that move the lines to `new`, to run inside the rows'
    /// animation block, and the views to remove when it ends. A kept line
    /// moves to its new frame, a new one starts at `start` (the line over
    /// its rows' start frames) so both its ends move with the rows, and a
    /// line whose group closed or left shrinks back up into its header.
    /// `animated`: the changes carry the fades only, and `springs` the frames,
    /// which the caller moves on the rows' render-server spring in the rows'
    /// own transaction (`RowMotion.animate`), so the move's end and the
    /// display's sleep reach the lines too (empty without motion).
    func update(_ new: [SidebarGroupLine], from start: [SidebarGroupLine], in list: NSView, above decorations: NSView, animated: Bool) -> LineMotion {
        lines = new
        var gone = views
        let starts = Dictionary(start.map { ($0.group, $0.frame) }, uniquingKeysWith: { first, _ in first })
        var moves: [(GroupLineView, CGRect)] = []
        for line in new {
            gone[line.group] = nil
            let view = views[line.group] ?? {
                let view = GroupLineView()
                view.isBlock = line.isBlock
                Self.place(view, in: list, decorations)
                views[line.group] = view
                Motion.withoutAnimation {
                    view.frame = animated ? starts[line.group] ?? Self.top(of: line.frame) : line.frame
                    // Fades in with its header, so it never shows over the
                    // members' fills before they indent.
                    view.alphaValue = animated ? 0 : 1
                }
                return view
            }()
            if view.isBlock != line.isBlock {
                view.isBlock = line.isBlock
                Self.place(view, in: list, decorations)
            }
            view.color = line.color
            view.strength = SidebarGroupLine.opacity(level: line.level)
            moves.append((view, line.frame))
        }
        var leaving: [(GroupLineView, CGRect)] = []
        for (group, view) in gone {
            views[group] = nil
            leaving.append((view, Self.top(of: view.frame)))
        }
        leavingViews.removeAll { $0.superview == nil }
        leavingViews += leaving.map(\.0)
        if animated {
            // The frames go to the caller's render-server springs (`springs`), every line's, an unmoved one's too
            // (with movement off that one's earlier spring comes off); only the fades run in the AppKit block.
            let changes = {
                for (view, _) in moves where view.alphaValue != 1 { view.animator().alphaValue = 1 }
                for (view, _) in leaving { view.animator().alphaValue = 0 }
            }
            return (changes, leaving.map(\.0), (moves + leaving).map { ($0.0 as NSView, $0.1) })
        }
        // Without motion the lines take their frames in one step: a spring an earlier move left on one comes off.
        SidebarDragSpring.stop(moves.map(\.0) + leaving.map(\.0))
        let changes = {
            for (view, frame) in moves {
                view.animator().frame = frame
                view.animator().alphaValue = 1
            }
            for (view, frame) in leaving {
                view.animator().frame = frame
                view.animator().alphaValue = 0
            }
        }
        return (changes, leaving.map(\.0), [])
    }

    /// Shows at once, at its frame, the line of each group in `lines` that has
    /// none (a group whose rows a drag hid: the last apply left its line out),
    /// and leaves every other line, moving or not, as it is. The shown line joins `lines`: a fold keeps the lines
    /// it does not touch from there, and without it the next fold took this line away.
    func showMissing(_ lines: [SidebarGroupLine], in list: NSView, above decorations: NSView) {
        for line in lines where views[line.group] == nil {
            self.lines.removeAll { $0.group == line.group }
            self.lines.insert(line, at: self.lines.firstIndex { $0.frame.minY > line.frame.minY } ?? self.lines.count) // list order
            let view = GroupLineView()
            view.isBlock = line.isBlock
            Self.place(view, in: list, decorations)
            views[line.group] = view
            Motion.withoutAnimation {
                view.frame = line.frame
                view.alphaValue = 1
            }
            view.color = line.color
            view.strength = SidebarGroupLine.opacity(level: line.level)
        }
    }

    /// Moves every line by `dy` at once, with the rows and the scroll offset.
    func shift(by dy: CGFloat) {
        for view in views.values { view.frame.origin.y += dy }
        // A line still fading out would stay at the old offset: it goes now.
        leavingViews.forEach { $0.removeFromSuperview() }
        leavingViews.removeAll()
    }

    /// Takes the rows' springs (`SidebarDragSpring.move(_:in:)`) off every line, the leaving ones too: the
    /// display went to sleep mid-move, so each line shows its frame now.
    func stopSprings() {
        SidebarDragSpring.stop(Array(views.values) + leavingViews.compactMap { $0 as? GroupLineView })
    }

    /// Puts each shown line exactly on its frame (`RowMotion.land`: the spring stops near it, not on it).
    func land() {
        for line in lines { views[line.group]?.frame = line.frame }
    }

    /// A rail sits among the rows, left of their fills. A block goes under every row, below `decorations` (the list's
    /// lowest view), so the rows' own hover, selection and drop fills draw over it.
    private static func place(_ view: GroupLineView, in list: NSView, _ decorations: NSView) {
        list.addSubview(view, positioned: view.isBlock ? .below : .above, relativeTo: decorations)
    }

    /// A line's zero-height start: its top edge, under the header bar.
    private static func top(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 0)
    }
}

/// One members' line, the sidebar's left bar: Chrome's (Leo 2026-10-19), a 2 pt bar in its header bar's exact color,
/// one capsule with the same round cap at the top and the bottom (Lawrence msg 19775, `SidebarGroupLineShape`).
/// The layer's corner clip draws the caps, so the line keeps its shape in every frame of the rows' spring.
final class GroupLineView: NSView {
    /// The view's bounds spring can keep presenting the old rail height after its model height reaches zero.
    /// Keep the shape taller than any sidebar line so the view, not the shape, clips the shrinking rail.
    private static let shapeCoverageHeight: CGFloat = 4096
    let railShape = CAShapeLayer()
    var color: GroupTint = .palette(.grey) {
        didSet { if color != oldValue { needsDisplay = true } }
    }
    /// The share of `color` the rail draws (`SidebarGroupLine.opacity(level:)`).
    var strength: CGFloat = 1 {
        didSet { if strength != oldValue { needsDisplay = true } }
    }
    /// A group with no color: the view is its block (`SidebarGroupLine.isBlock`), a neutral surface in the
    /// `sidebar.noColorGroup` look, not a rail.
    var isBlock = false {
        didSet { if isBlock != oldValue { needsDisplay = true; needsLayout = true } }
    }
    /// The lit block's light (`SidebarNoColorGroupLook.lit`).
    private let light = CAGradientLayer()
    /// The block's specular rim (`SurfaceRole.group`, `SidebarNoColorGroupLook.glass`).
    let rim = GlassRimView(cornerRadius: SidebarStyle.rowCornerRadius, look: FloatingGlassStyle.group.look(isDark: true))

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true // the corner clip draws the capsule's caps (`updateShape`)
        railShape.fillColor = NSColor.black.cgColor
        layer?.addSublayer(railShape)
        light.isHidden = true
        light.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(light)
        rim.isHidden = true
        rim.autoresizingMask = [.width, .height]
        addSubview(rim)
        ReduceTransparency.shared.register(repainting: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateShape()
    }

    override func updateLayer() {
        let look = observedLook()
        if isBlock { return paintBlock(look.noColor) }
        light.isHidden = true
        rim.isHidden = true
        layer?.borderWidth = 0
        performWithTheme {
            // Under the solid band, the band's rest color (Leo 2026-10-19: bar and line are one color);
            // the quieter looks keep the dot's color.
            // Under a glass band, the pane's vivid color (`GroupTint.glassRGB`), so rail and rim read as one group.
            let line = look.style != .band ? color.lineColor(themed: look.themed)
                : look.glass == .solid || color.isNone ? color.lineFill(themed: look.themed) : color.glassRGB(themed: look.themed).nsColor
            layer?.backgroundColor = NSColor.clear.cgColor
            railShape.fillColor = line.withAlphaComponent(line.alphaComponent * strength).cgColor
        }
        updateShape()
    }

    /// A block's surface: the shared `group` surface role untinted (`SurfaceRole.group`), its veil over the sidebar's own
    /// glass and, in the glass look, its rim (`GlassRimView`), under the rows' own hover and selection. Under Reduce
    /// Transparency the role's opaque fallback: the veil composited over the sidebar's opaque background, a hairline.
    private func paintBlock(_ look: SidebarNoColorGroupLook) {
        performWithTheme {
            let tokens = themeTokens, opaque = ReduceTransparency.shared.isEnabled
            let role = FloatingGlassStyle.group.look(isDark: tokens.isDark)
            let veil = ThemeRGB(red: role.veil.white, green: role.veil.white, blue: role.veil.white, alpha: role.veil.alpha * strength)
            railShape.fillColor = nil
            let fill = opaque ? veil.composited(over: tokens.sidebarBackground) : veil
            layer?.backgroundColor = look == .lit && !opaque ? NSColor.clear.cgColor : fill.cgColor
            layer?.borderWidth = opaque ? Metrics.lineWidth(1) : 0
            layer?.borderColor = tokens.separator.cgColor
            rim.look = role
            rim.cornerRadius = SidebarStyle.rowCornerRadius
            rim.isHidden = opaque || look != .glass
            light.isHidden = opaque || look != .lit
            let top = role.rimTop.nsColor.withAlphaComponent(role.rimTop.alpha * 0.25).cgColor
            light.colors = [top, veil.cgColor, veil.cgColor]
        }
        updateShape()
    }

    private func updateShape() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if isBlock {
            // A rounded block with the rows' own corner; the light fades over its first two rows.
            layer?.cornerRadius = SidebarStyle.rowCornerRadius
            layer?.maskedCorners = SidebarGroupLine.barCorners(open: false, flipped: true)
            railShape.path = nil
            rim.frame = bounds
            light.frame = bounds
            light.locations = [0, NSNumber(value: Double(min(1, 2 * SidebarDensityTokens.rowHeight / max(bounds.height, 1)))), 1]
            return
        }
        // The clipping layer owns both caps (one capsule, `SidebarGroupLineShape`), so they follow the presentation
        // bounds through a fold; rounding the oversized body instead would clip the bottom cap off the visible rail.
        layer?.cornerRadius = SidebarGroupLineShape.cornerRadius(width: bounds.width)
        layer?.maskedCorners = SidebarGroupLineShape.corners
        let height = max(bounds.height, railShape.frame.height, Self.shapeCoverageHeight)
        railShape.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        railShape.path = SidebarGroupLineShape.body(width: bounds.width, height: height)
    }

    /// Reads `sidebar.groupHeader`, `sidebar.groupColors`, `sidebar.noColorGroup` and `sidebar.groupGlass` and repaints once when either changes; one
    /// observation at a time.
    private func observedLook() -> (style: SidebarGroupHeaderStyle, themed: Bool, noColor: SidebarNoColorGroupLook, glass: SidebarGroupGlass) {
        let read = {
            _ = SidebarTunables.groupChromeShapeOn
            return (SidebarGroupHeaderStyle.tunable.value, SidebarGroupPalette.tunable.value == .theme, SidebarNoColorGroupLook.tunable.value,
                    SidebarGroupGlass.tunable.value)
        }
        guard !observesPalette else { return read() }
        observesPalette = true
        return withObservationTracking(read) { [weak self] in
            Task { @MainActor [weak self] in
                self?.observesPalette = false
                self?.needsDisplay = true
            }
        }
    }

    private var observesPalette = false
}
