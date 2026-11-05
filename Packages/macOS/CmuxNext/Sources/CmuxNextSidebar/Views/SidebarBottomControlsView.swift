import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The bottom-left controls of a ``SidebarBottomControlsVariant`` other than `.standard`: the larger avatar,
/// the wide Search field and the named account row. Search's square stays the sidebar's own
/// `searchButton`, resized; the footer's avatar tile stays in its region, clear, under this view's avatar.
/// The view takes clicks only on its controls, so the spaces strip between them keeps its own.
final class SidebarBottomControlsView: NSView {
    let avatarButton = SidebarBottomAvatarButton()
    let searchField = SidebarBottomSearchField()
    let accountRow = SidebarBottomAccountRow()

    nonisolated override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for control in [avatarButton, searchField, accountRow] as [NSView] {
            control.isHidden = true
            addSubview(control)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Shows the controls `geometry` places (frames in the sidebar's coordinates; this view covers it).
    func apply(_ geometry: SidebarBottomControlsGeometry?, avatar: SidebarAvatar?) {
        func place(_ view: NSView, _ rect: CGRect?) {
            view.isHidden = rect == nil
            if let rect { view.frame = rect }
        }
        place(avatarButton, geometry?.avatar)
        place(searchField, geometry?.searchField)
        place(accountRow, geometry?.accountRow)
        avatarButton.avatar = avatar
        accountRow.avatar = avatar
    }
}

/// A square control with the sidebar's hover fill (through ``ChromeHover``, so its fades obey the Motion
/// gates) that runs ``onPress`` on a click.
class SidebarBottomControl: NSView {
    var onPress: (() -> Void)?
    private let cornerRadius: CGFloat
    /// The fill is the view's own layer, under what `draw(_:)` paints.
    private(set) lazy var hover = ChromeHover(self, cornerRadius: cornerRadius, behindContent: true)

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        hover.followPointer(onChange: { [weak self] in self?.needsDisplay = true })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        hover.layout()
    }

    override func mouseDown(with event: NSEvent) {
        hover.state.pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        hover.state.pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress, !isHiddenOrHasHiddenAncestor else { return false }
        onPress()
        return true
    }

    override func isAccessibilityElement() -> Bool { true }

    /// Keeps the hover fill while a menu this control opened is open.
    var showsMenu = false { didSet { hover.state.lit = showsMenu } }

    var isStrong: Bool { hover.state.hovering || hover.state.pressed || showsMenu }
}

/// The avatar as a full-size target: a circle that stays truly round (its hover fill is the square's
/// inscribed circle), with the picture or initial at the row's icon size plus a step.
final class SidebarBottomAvatarButton: SidebarBottomControl {
    var avatar: SidebarAvatar? {
        didSet {
            guard avatar != oldValue else { return }
            setAccessibilityLabel(avatar?.toolTip)
            toolTip = avatar?.toolTip
            needsDisplay = true
        }
    }

    init() {
        super.init(cornerRadius: 0)
        setAccessibilityRole(.menuButton)
    }

    override func layout() {
        super.layout()
        // A circle: half the side of a square that is pixel-aligned, so the fill is round and crisp.
        // `.circular`: a continuous curve at half the side draws a squircle, not a circle.
        layer?.cornerCurve = .circular
        layer?.cornerRadius = bounds.width / 2
    }

    /// The drawn circle: 4 pt inside the hit square, on whole points.
    var circleFrame: NSRect {
        let d = (bounds.width - 2 * Metrics.space2).rounded(.down)
        return NSRect(x: ((bounds.width - d) / 2).rounded(), y: ((bounds.height - d) / 2).rounded(), width: d, height: d)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let avatar else { return }
        performWithTheme { SidebarAvatarView.draw(avatar, in: circleFrame, strong: isStrong) }
    }
}

/// The wide Search field across the bottom: a rounded rectangle (never a capsule) with the magnifying
/// glass on the leading column and "Search" in the tertiary text color.
final class SidebarBottomSearchField: SidebarBottomControl {
    init() {
        super.init(cornerRadius: Metrics.itemCornerRadius)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Strings.searchButton)
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            // The field's own well under the hover fill, a hairline inside its edge.
            let well = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: Metrics.itemCornerRadius, yRadius: Metrics.itemCornerRadius)
            Palette.hoverFill.setFill()
            well.fill()
            Palette.separator.setStroke()
            well.lineWidth = 1 / (window?.backingScaleFactor ?? 2)
            well.stroke()
            let glyphSide = CGFloat.iconRowSize(forLabelPointSize: Metrics.iconSize)
            // The glass centers where the avatar's circle would: on the leading column.
            let glyph = NSRect(x: ((bounds.height - glyphSide) / 2).rounded(), y: ((bounds.height - glyphSide) / 2).rounded(),
                               width: glyphSide, height: glyphSide)
            let ink = isStrong ? Palette.textPrimary : Palette.textSecondary
            NSImage.icon(.search, size: glyphSide).tinted(ink).draw(in: glyph)
            let font = SidebarStyle.titleFont
            let text = NSAttributedString(string: Strings.searchButton, attributes: [.font: font, .foregroundColor: Palette.textTertiary])
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.height, y: ((bounds.height - size.height) / 2).rounded()))
        }
    }
}

/// The profile as a named account row: the avatar, the profile's name, and the up-down chevron that says
/// the row opens a menu, on the list rows' rounded-rectangle hover.
final class SidebarBottomAccountRow: SidebarBottomControl {
    var avatar: SidebarAvatar? {
        didSet {
            guard avatar != oldValue else { return }
            setAccessibilityLabel(avatar?.toolTip)
            needsDisplay = true
        }
    }

    init() {
        super.init(cornerRadius: Metrics.itemCornerRadius)
        setAccessibilityRole(.menuButton)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let avatar else { return }
        performWithTheme {
            let h = bounds.height
            // The avatar's circle on the leading column, as the avatar button draws it.
            let d = (h - 2 * Metrics.space2).rounded(.down)
            let circle = NSRect(x: ((h - d) / 2).rounded(), y: ((h - d) / 2).rounded(), width: d, height: d)
            SidebarAvatarView.draw(avatar, in: circle, strong: isStrong)
            let chevronSide = CGFloat.iconRowSize(forLabelPointSize: Metrics.smallIconSize)
            let chevron = NSRect(x: (bounds.width - h / 2 - chevronSide / 2).rounded(), y: ((h - chevronSide) / 2).rounded(),
                                 width: chevronSide, height: chevronSide)
            NSImage.icon(symbol: "chevron.up.chevron.down", size: chevronSide).tinted(Palette.textSecondary).draw(in: chevron)
            let name = NSAttributedString(string: avatar.name, attributes: [
                .font: SidebarStyle.titleFont, .foregroundColor: isStrong ? Palette.textPrimary : Palette.textSecondary,
            ])
            let x = h, width = max(0, chevron.minX - Metrics.space2 - x)
            let size = name.size()
            name.draw(with: NSRect(x: x, y: ((h - size.height) / 2).rounded(), width: width, height: size.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
