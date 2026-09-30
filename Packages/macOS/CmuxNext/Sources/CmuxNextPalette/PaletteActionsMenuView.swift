import AppKit
import CmuxNextDesign

/// The Cmd-K menu: every command of the selected item on a small glass
/// panel, filterable by typing. Rebuilt when it opens or its filter changes
/// (a handful of rows), so it needs no reuse.
final class PaletteActionsMenuView: NSView {
    var onRun: ((Int) -> Void)?

    private let glass = Glass.makePanel(cornerRadius: PaletteLayout.cornerRadius)
    private let content = FlippedView()
    private let title = PaletteText.label(Typography.header, color: Palette.textSecondary)
    private let filter = PaletteText.label(Typography.body, color: Palette.textTertiary)
    private let separator = NSView()
    private var rowViews: [PaletteMenuRow] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.contentView = content
        separator.wantsLayer = true
        [title, separator, filter].forEach(content.addSubview)
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Height the menu wants for `state`.
    static func height(for state: PaletteActionsMenuState) -> CGFloat {
        let rows = CGFloat(max(1, state.visibleCommands.count))
        return Metrics.space4 + PaletteLayout.headerRowHeight + rows * PaletteLayout.actionsMenuRowHeight
            + Metrics.space2 + Metrics.dividerThickness + PaletteLayout.actionsMenuRowHeight
    }

    func update(_ state: PaletteActionsMenuState, alternateID: String?) {
        title.stringValue = state.itemTitle
        filter.stringValue = state.filter.isEmpty ? PaletteStrings.searchActionsPlaceholder : state.filter
        filter.textColor = state.filter.isEmpty ? Palette.textTertiary : Palette.textPrimary
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = state.visibleCommands.enumerated().map { index, command in
            let keycaps: [String]? = index == 0 && state.filter.isEmpty ? ["↩"] : (command.id == alternateID ? ["⌘", "↩"] : nil)
            let row = PaletteMenuRow(command: command, keycaps: keycaps, isSelected: index == state.selectedIndex)
            row.onClick = { [weak self] in self?.onRun?(index) }
            content.addSubview(row)
            return row
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        let inset = Metrics.space2
        let padding = PaletteLayout.horizontalPadding
        var y = Metrics.space4
        let titleHeight = title.intrinsicContentSize.height
        title.frame = NSRect(x: padding, y: y, width: bounds.width - 2 * padding, height: titleHeight)
        y = Metrics.space4 + PaletteLayout.headerRowHeight
        for row in rowViews {
            row.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: PaletteLayout.actionsMenuRowHeight)
            y += PaletteLayout.actionsMenuRowHeight
        }
        y += Metrics.space2
        separator.frame = NSRect(x: 0, y: y, width: bounds.width, height: Metrics.dividerThickness)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            separator.layer?.backgroundColor = Palette.separator.cgColor
        }
        y += Metrics.dividerThickness
        let filterHeight = filter.intrinsicContentSize.height
        filter.frame = NSRect(x: padding, y: y + (PaletteLayout.actionsMenuRowHeight - filterHeight) / 2,
                              width: bounds.width - 2 * padding, height: filterHeight)
    }
}

/// One command row in the Actions menu.
final class PaletteMenuRow: NSView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = PaletteText.label(Typography.body)
    private let keys = PaletteKeycapsView()
    private let isSelected: Bool

    init(command: PaletteCommand, keycaps: [String]?, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        icon.image = PaletteText.symbol(command.symbol ?? "circle", size: Metrics.smallIconSize)
        icon.contentTintColor = Palette.textSecondary
        label.stringValue = command.title
        label.textColor = command.isDestructive ? Palette.textSecondary : Palette.textPrimary
        keys.keycaps = keycaps ?? []
        keys.isHidden = keycaps == nil
        [icon, label, keys].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        Palette.selectionFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: PaletteLayout.rowCornerRadius, yRadius: PaletteLayout.rowCornerRadius).fill()
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
            keys.frame = NSRect(x: right, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            right -= Metrics.space4
        }
        let x = icon.frame.maxX + Metrics.space4
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, right - x), height: height)
    }
}

/// Top-left origin container.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
