import AppKit
import CmuxNextDesign
import QuartzCore

final class SectionHeaderRowView: SidebarRowView {
    private let glyph = NSImageView()
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont, color: Palette.textTertiary)
    private let status = CALayer()
    private let chevron = NSImageView()
    private let separator = CALayer()
    let addButton = SidebarIconButton(symbol: "plus", pointSize: { Metrics.smallIconSize - Metrics.space1 }, weight: .semibold, label: Strings.newWorkspace)
    private var statusColor: NSColor?
    private var collapsed = false
    var onAdd: (() -> Void)?

    required init(key: SidebarRowKey) {
        super.init(key: key)
        glyph.contentTintColor = Palette.textSecondary
        chevron.contentTintColor = Palette.textTertiary
        layer?.addSublayer(status)
        layer?.addSublayer(separator)
        [glyph, name, chevron, addButton].forEach(addSubview)
        addButton.onPress = { [weak self] in self?.onAdd?() }
    }

    override var interactiveSubviews: [NSView] { [addButton] }

    private struct Content: Hashable {
        // The section's kind, not its nodes: comparing 1,000 children per
        // reload would defeat the point.
        var kind: SidebarSection.Kind
        var collapsed: Bool
        var compact: Bool
        var fontSize: CGFloat
        var iconSize: CGFloat
    }

    func configure(_ section: SidebarSection, row: SidebarRow, compact: Bool) {
        let content = Content(
            kind: section.kind, collapsed: row.isCollapsed, compact: compact,
            fontSize: SidebarStyle.headerFont.pointSize, iconSize: Metrics.smallIconSize
        )
        guard needsConfigure(content) else { return }
        self.compact = compact
        collapsed = row.isCollapsed
        let symbol: String
        let title: String
        switch section.kind {
        case .pinned:
            symbol = "pin.fill"
            title = Strings.pinned
            statusColor = nil
        case let .machine(machine):
            switch machine.kind {
            case .local: symbol = "laptopcomputer"
            case .cloud: symbol = "cloud.fill"
            case .ssh: symbol = "server.rack"
            }
            title = machine.name
            switch (machine.kind, machine.status) {
            case (.local, .connected): statusColor = nil
            case (_, .connected): statusColor = Palette.success
            case (_, .connecting): statusColor = Palette.attention
            case (_, .offline): statusColor = Palette.textTertiary
            }
            var label = machine.name
            switch machine.status {
            case .connected: label += ", " + Strings.statusConnected
            case .connecting: label += ", " + Strings.statusConnecting
            case .offline: label += ", " + Strings.statusOffline
            }
            setAccessibilityLabel(label)
        }
        if section.kind == .pinned { setAccessibilityLabel(title) }
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize - Metrics.space1, weight: .semibold))
        name.stringValue = title
        name.font = SidebarStyle.headerFont
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(SidebarStyle.chevronConfig)
        toolTip = compact ? title : nil
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityExpanded(!collapsed)
        addButton.isHidden = true
        needsLayout = true
        needsDisplay = true
    }

    var allowsAdd = true

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        status.backgroundColor = statusColor.map(resolvedCGColor)
        status.isHidden = statusColor == nil || compact
        separator.backgroundColor = resolvedCGColor(Palette.separator)
        separator.isHidden = !compact
        CATransaction.commit()
        layer?.backgroundColor = nil
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if compact {
            [glyph, name, chevron, addButton].forEach { $0.isHidden = true }
            separator.frame = CGRect(x: Metrics.space4, y: (b.height - Metrics.dividerThickness) / 2, width: b.width - Metrics.space6, height: Metrics.dividerThickness)
            needsDisplay = true
            return
        }
        // Quiet text header: no glyph, the name aligns with row titles.
        glyph.isHidden = true
        name.isHidden = false
        let nameX = SidebarStyle.horizontalInset
        var trailing = b.width - Metrics.space2
        addButton.isHidden = !(isHovered && allowsAdd)
        let control = SidebarStyle.controlSize
        if !addButton.isHidden {
            addButton.frame = NSRect(x: trailing - control, y: (b.height - control) / 2, width: control, height: control)
            trailing -= control + Metrics.space1
        }
        chevron.isHidden = !(isHovered || collapsed)
        let chevronSide = Metrics.smallIconSize
        chevron.frame = NSRect(x: trailing - chevronSide, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        trailing -= chevronSide + Metrics.space2
        let nw = min(ceil(name.attributedStringValue.size().width) + Metrics.space2, max(0, trailing - nameX - Metrics.space5))
        let nh = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: nameX, y: (b.height - nh) / 2, width: nw, height: nh)
        let dot = SidebarStyle.dotSize
        status.frame = CGRect(x: name.frame.maxX + Metrics.space2, y: (b.height - dot) / 2, width: dot, height: dot)
        status.cornerRadius = dot / 2
        needsDisplay = true
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }
}

// MARK: - Empty section drop zone
