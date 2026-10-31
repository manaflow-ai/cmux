import AppKit
import CmuxNextDesign
import QuartzCore

/// The Cmd-K menu: every command of the selected item on a small glass
/// popup (`PopupStyle`; the palette's own shadow covers it), filterable by typing. Rebuilt when it opens or its filter changes
/// (a handful of rows), so it needs no reuse.
final class PaletteActionsMenuView: NSView {
    var onRun: ((Int) -> Void)?
    /// The pointer moved onto the row at this index: the selection follows it.
    var onHover: ((Int) -> Void)?

    /// The panel's material: glass, or opaque under Reduce Transparency.
    let glass = Glass.makeOverlayPanel(cornerRadius: PopupStyle.standard.cornerRadius)
    private let content = FlippedView()
    private let title = PaletteText.label(Typography.header, tone: .secondary)
    private let filter = PaletteText.label(Typography.body, tone: .tertiary)
    /// Shown in the one row a filter that matches nothing keeps, instead of a blank row.
    private let empty = PaletteText.label(Typography.body, tone: .tertiary)
    private let separator = NSView()
    private var rowViews: [PaletteMenuRow] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.contentView.addSubview(content)
        separator.wantsLayer = true
        empty.stringValue = PaletteStrings.noResults
        [title, separator, filter, empty].forEach(content.addSubview)
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The corner the menu grows from: its bottom trailing corner, above the
    /// footer's "Actions ⇥" (layer coordinates, origin at the bottom left).
    var scalePivot: CGPoint { CGPoint(x: bounds.width, y: 0) }

    /// The menu's contents scaled about `scalePivot`, for its layer's
    /// `sublayerTransform`.
    func scaled(_ scale: CGFloat) -> CATransform3D {
        guard let layer else { return CATransform3DIdentity }
        return Motion.scale(scale, about: scalePivot, in: layer)
    }

    /// Height the menu wants for `state`.
    static func height(for state: PaletteActionsMenuState) -> CGFloat {
        let rows = CGFloat(max(1, state.visibleCommands.count))
        return Metrics.space4 + PaletteLayout.headerRowHeight + rows * PaletteLayout.actionsMenuRowHeight
            + Metrics.space2 + Metrics.dividerThickness + PaletteLayout.actionsMenuRowHeight
    }

    func update(_ state: PaletteActionsMenuState, alternateID: String?) {
        title.stringValue = state.itemTitle
        filter.stringValue = state.filter.isEmpty ? PaletteStrings.searchActionsPlaceholder : state.filter
        filter.tone = state.filter.isEmpty ? .tertiary : .primary
        rowViews.forEach { $0.removeFromSuperview() }
        empty.isHidden = !state.visibleCommands.isEmpty
        rowViews = state.visibleCommands.enumerated().map { index, command in
            let keycaps: [String]? = index == 0 && state.filter.isEmpty ? ["↩"] : (command.id == alternateID ? ["⌘", "↩"] : nil)
            let row = PaletteMenuRow(command: command, keycaps: keycaps, isSelected: index == state.selectedIndex)
            row.onPress = { [weak self] event in self?.track(event) }
            row.onHover = { [weak self] in self?.onHover?(index) }
            content.addSubview(row)
            return row
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = CGRect(origin: .zero, size: glass.bounds.size)
        let inset = Metrics.space2
        let padding = PaletteLayout.horizontalPadding
        var y = Metrics.space4
        let titleHeight = PaletteText.height(title)
        title.frame = content.pixelAligned(NSRect(x: padding, y: y, width: bounds.width - 2 * padding, height: titleHeight))
        y = Metrics.space4 + PaletteLayout.headerRowHeight
        let emptyHeight = PaletteText.height(empty)
        empty.frame = content.pixelAligned(NSRect(x: padding, y: y + (PaletteLayout.actionsMenuRowHeight - emptyHeight) / 2,
                                                  width: bounds.width - 2 * padding, height: emptyHeight))
        if rowViews.isEmpty { y += PaletteLayout.actionsMenuRowHeight }
        for row in rowViews {
            row.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: PaletteLayout.actionsMenuRowHeight)
            y += PaletteLayout.actionsMenuRowHeight
        }
        y += Metrics.space2
        separator.frame = NSRect(x: 0, y: y, width: bounds.width, height: Metrics.dividerThickness)
        applyColors()
        y += Metrics.dividerThickness
        let filterHeight = PaletteText.height(filter)
        filter.frame = content.pixelAligned(NSRect(x: padding, y: y + (PaletteLayout.actionsMenuRowHeight - filterHeight) / 2,
                                                   width: bounds.width - 2 * padding, height: filterHeight))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// A press on a row: the selection follows a drag and the release runs the row it ends on.
    private func track(_ event: NSEvent) {
        PalettePress.track(event, in: content, row: { point in
            self.rowViews.firstIndex { $0.frame.contains(point) }
        }, select: { index in
            self.onHover?(index)
        }, release: { index in
            self.onRun?(index)
        })
    }

    private func applyColors() {
        performWithTheme {
            glass.applyTheme()
            separator.layer?.backgroundColor = Palette.separator.cgColor
        }
    }
}

/// One command row in the Actions menu.
final class PaletteMenuRow: NSView {
    var onPress: ((NSEvent) -> Void)?
    var onHover: (() -> Void)?
    private let icon = NSImageView()
    private let label = PaletteText.label(Typography.body)
    private let keys = PaletteKeycapsView()
    private let isSelected: Bool
    /// Whether the row's label is the quiet (destructive) tone; its icon takes the same ink.
    private let isQuiet: Bool

    init(command: PaletteCommand, keycaps: [String]?, isSelected: Bool) {
        self.isSelected = isSelected
        isQuiet = command.isDestructive
        super.init(frame: .zero)
        icon.image = PaletteText.symbol(command.symbol ?? "command", size: Metrics.smallIconSize)
        label.stringValue = command.title
        label.tone = command.isDestructive ? .secondary : .primary
        keys.keycaps = keycaps ?? []
        keys.isHidden = keycaps == nil
        [icon, label, keys].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    nonisolated override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPress?(event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        performWithTheme {
            Palette.selectionFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: PaletteLayout.rowCornerRadius, yRadius: PaletteLayout.rowCornerRadius).fill()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        // The icon takes its label's ink, as a native menu row's does (user 2026-10-21: menu
        // icons "should be whiter").
        performWithTheme { icon.contentTintColor = isQuiet ? Palette.textSecondary : Palette.textPrimary }
    }

    override func layout() {
        super.layout()
        let padding = Metrics.space4
        let box = PaletteLayout.iconBox
        icon.frame = NSRect(x: padding, y: (bounds.height - box) / 2, width: box, height: box)
        var right = bounds.maxX - padding
        if !keys.isHidden {
            let size = keys.intrinsicContentSize
            right -= size.width
            keys.frame = pixelAligned(NSRect(x: right, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            right -= Metrics.space4
        }
        let x = icon.frame.maxX + Metrics.space4
        let height = PaletteText.height(label)
        label.frame = pixelAligned(NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, right - x), height: height))
    }
}

/// Top-left origin container.
final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}
