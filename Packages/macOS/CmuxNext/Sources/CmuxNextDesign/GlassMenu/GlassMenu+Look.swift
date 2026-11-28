public import AppKit
import CmuxNextDesignTokens

/// A theme file's menu look (``MenuLook``, `appearance.menu.*`) on a ``GlassMenu``: read at each open,
/// so a saved theme file shows on the next menu with no relaunch. The standard look (every key unset)
/// leaves today's menu exactly as it was: the popup radius, the glass and its veil, the one popover
/// shadow and the menu grid.
extension GlassMenu {
    /// Applies `look` to the panel and its rows (the rows read it as they load).
    func applyLook(_ look: MenuLook) {
        let radius = look.cornerRadius ?? GlassMenuMaterial.cornerRadius
        surface.cornerRadius = radius
        if let host = panel.contentView as? PopupHostView {
            host.cornerRadius = radius
            host.elevation = look.shadow.elevation
        }
        list.look = look
        guard look.fill != nil || look.borderOpacity != nil else {
            lookView?.removeFromSuperview()
            lookView = nil
            return
        }
        let view = lookView ?? GlassMenuLookView(frame: surface.contentView.bounds)
        if lookView == nil {
            view.autoresizingMask = [.width, .height]
            surface.contentView.addSubview(view, positioned: .below, relativeTo: list)
            lookView = view
        }
        view.update(fill: look.fill, borderOpacity: look.borderOpacity, cornerRadius: radius)
    }

    /// Where a submenu opens for its row at `row` (screen): the row itself under the standard look,
    /// or, under `flush`, an anchor that puts the submenu's panel against this menu's edge with its
    /// first row level with `row` (``MenuLook/Submenu/flush``).
    func submenuAnchor(row: CGRect) -> CGRect {
        let look = list.look
        guard look.submenu == .flush else { return row }
        let card = panel.convertToScreen(surface.convert(surface.bounds, to: nil))
        return Self.flushAnchor(row: row, card: card, padding: look.resolvedPadding)
    }

    /// The anchor ``PopupPlacement/sideBySideFrame(anchor:size:screen:gap:margin:)`` places a flush
    /// submenu from: the menu card's horizontal edges less the side gap (so the submenu's edge meets
    /// the card's), and the row's top raised by the submenu's padding (so its first row meets `row`).
    nonisolated static func flushAnchor(row: CGRect, card: CGRect, padding: CGFloat,
                                        gap: CGFloat = PopupPlacement.sideGap) -> CGRect {
        let minX = card.minX + gap
        let maxX = max(minX, card.maxX - gap)
        return CGRect(x: minX, y: row.minY, width: maxX - minX, height: row.height + padding)
    }
}

/// The theme file's fill and edge over a ``GlassMenu``'s glass (`appearance.menu.fill`,
/// `appearance.menu.borderOpacity`), under its rows. It never takes a click.
@MainActor
final class GlassMenuLookView: NSView {
    private var fill: ThemeRGB?
    private var borderOpacity: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    func update(fill: ThemeRGB?, borderOpacity: CGFloat?, cornerRadius: CGFloat) {
        self.fill = fill
        self.borderOpacity = borderOpacity
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.backgroundColor = fill.map { $0.nsColor.cgColor } ?? NSColor.clear.cgColor
        guard let borderOpacity, Borders.drawsLines else {
            layer?.borderWidth = 0
            return
        }
        layer?.borderWidth = Metrics.lineWidth(1 / max(window?.backingScaleFactor ?? 2, 1))
        layer?.borderColor = performWithTheme { Palette.textPrimary.withAlphaComponent(borderOpacity) }.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
