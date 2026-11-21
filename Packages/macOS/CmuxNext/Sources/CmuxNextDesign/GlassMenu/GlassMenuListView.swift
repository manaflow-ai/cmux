import AppKit

/// The rows of a ``GlassMenu`` on the menu grid: ``MenuMetrics/highlightInset`` around them, the
/// icon at ``MenuMetrics/iconX``, the text on ``MenuMetrics/textX(iconColumn:stateColumn:)``, the
/// shortcut or chevron ``MenuMetrics/trailing`` from the edge, rows ``GlassMenuMaterial/rowHeight``
/// high, separators a hairline ``MenuMetrics/separatorInset`` in from the edges.
@MainActor
final class GlassMenuListView: NSView {
    var onPick: (Int) -> Void = { _ in }
    var onOpenSubmenu: (Int) -> Void = { _ in }
    var onHoverRow: (Int) -> Void = { _ in }
    var onBack: () -> Void = {}
    /// A key equivalent of one of the menu's items was pressed while the menu had the keys.
    var onKeyEquivalent: (NSEvent) -> Bool = { _ in false }

    private var rows: [GlassMenuRow] = []
    private var views: [NSView] = []
    private var highlighted: Int?
    /// The rows' least and most width (points): a menu is as wide as its longest row within them.
    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 360
    static let separatorHeight: CGFloat = 9

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func load(_ rows: [GlassMenuRow]) {
        self.rows = rows
        highlighted = nil
        views.forEach { $0.removeFromSuperview() }
        let iconColumn = rows.contains { $0.item?.image != nil }
        views = rows.enumerated().map { index, row in
            guard let item = row.item else { return GlassMenuSeparatorView() }
            let view = makeRow(item, iconColumn: iconColumn)
            view.onActivate = { [weak self] in self?.onPick(index) }
            view.onHover = { [weak self] in self?.onHoverRow(index) }
            return view
        }
        views.forEach(addSubview)
        setAccessibilityRole(.menu)
    }

    private func makeRow(_ item: NSMenuItem, iconColumn: Bool) -> PopupRowView {
        var layout = PopupRowView.Layout()
        let inset = MenuMetrics.highlightInset
        layout.leading = MenuMetrics.iconX - inset
        layout.leadingColumn = iconColumn ? MenuMetrics.iconSize : 0
        layout.gap = iconColumn ? MenuMetrics.iconGap : 0
        layout.trailing = MenuMetrics.trailing - inset
        layout.trailingGap = MenuMetrics.shortcutGap
        layout.minHeight = GlassMenuMaterial.rowHeight
        layout.hoverFills = false
        var subtitle: String?
        if #available(macOS 14.4, *) { subtitle = item.subtitle }
        let row = PopupRowView(leading: iconColumn ? icon(item.image) : nil, title: item.title, subtitle: subtitle,
                               trailing: trailing(item), layout: layout)
        row.isEnabled = item.isEnabled
        if let identifier = item.identifier { row.setAccessibilityIdentifier(identifier.rawValue) }
        row.setAccessibilityRole(.menuItem)
        return row
    }

    private func icon(_ image: NSImage?) -> NSView {
        let view = ThemedImageView()
        view.image = image?.fittedToMenuIconBox()
        view.imageScaling = .scaleProportionallyDown
        if image?.isTemplate ?? true { view.ink = .primary }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: MenuMetrics.iconSize),
            view.heightAnchor.constraint(equalToConstant: MenuMetrics.iconSize),
        ])
        return view
    }

    private func trailing(_ item: NSMenuItem) -> NSView? {
        if item.submenu != nil { return symbol("chevron.right", ink: .tertiary) }
        if item.state == .on { return symbol("checkmark", ink: .primary) }
        if item.state == .mixed { return symbol("minus", ink: .primary) }
        return GlassMenuRow.shortcut(item).map(PopupRowView.shortcut)
    }

    private func symbol(_ name: String, ink: ThemeInk) -> NSView {
        let view = ThemedImageView()
        view.image = NSImage.menuSymbol(name)
        view.ink = ink
        return view
    }

    /// The size the rows ask for: the widest row within ``minWidth`` and ``maxWidth``, every row's
    /// height and the inset above and below.
    func fittingMenuSize() -> CGSize {
        let inset = MenuMetrics.highlightInset
        var width = Self.minWidth
        var height = inset * 2
        for view in views {
            let size = view.fittingSize
            width = max(width, size.width + inset * 2)
            height += view is GlassMenuSeparatorView ? Self.separatorHeight : max(size.height, GlassMenuMaterial.rowHeight)
        }
        return CGSize(width: min(width, Self.maxWidth).rounded(.up), height: height.rounded(.up))
    }

    override func layout() {
        super.layout()
        let inset = MenuMetrics.highlightInset
        var y = inset
        for view in views {
            let height = view is GlassMenuSeparatorView ? Self.separatorHeight
                : max(view.fittingSize.height, GlassMenuMaterial.rowHeight)
            view.frame = CGRect(x: inset, y: y, width: bounds.width - inset * 2, height: height)
            y += height
        }
    }

    func row(at index: Int) -> GlassMenuRow? { rows.indices.contains(index) ? rows[index] : nil }
    /// The row whose view holds `point` (the list's coordinates), or nil on the inset.
    func index(at point: CGPoint) -> Int? { views.firstIndex { $0.frame.contains(point) } }
    func view(at index: Int) -> NSView? { views.indices.contains(index) ? views[index] : nil }

    func highlight(_ index: Int?) {
        highlighted = index
        for (offset, view) in views.enumerated() { (view as? PopupRowView)?.isHighlighted = offset == index }
    }

    func highlightFirst() { highlight(step(from: nil, by: 1)) }

    /// The next enabled row from `index` in `direction`, wrapping.
    private func step(from index: Int?, by direction: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        var next = index ?? (direction > 0 ? -1 : rows.count)
        for _ in rows.indices {
            next = (next + direction + rows.count) % rows.count
            if let item = rows[next].item, item.isEnabled { return next }
        }
        return nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: highlight(step(from: highlighted, by: 1))  // Down
        case 126: highlight(step(from: highlighted, by: -1))  // Up
        case 124: if let highlighted { onOpenSubmenu(highlighted) }  // Right
        case 123: onBack()  // Left (Escape is the popup host's: it closes the whole menu)
        case 36, 76, 49: if let highlighted { onPick(highlighted) }  // Return, Enter, Space
        default: if !onKeyEquivalent(event) { super.keyDown(with: event) }
        }
    }

    /// A shortcut pressed while the menu is open runs its row, as it does in an open `NSMenu`
    /// (⌘, opens Settings), instead of going nowhere.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

}
