import AppKit
import CmuxNextDesign

/// Base class for every row. Rows are passive: the list view owns mouse
/// handling, hover, and drag, so rows return nil from hit testing except for
/// their own buttons.
class SidebarRowView: NSView {
    var key: SidebarRowKey
    var compact = false { didSet { if compact != oldValue { needsLayout = true } } }
    var isHovered = false { didSet { if isHovered != oldValue { hoverChanged() } } }

    init(key: SidebarRowKey) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in interactiveSubviews where !button.isHidden && button.frame.contains(local) {
            return button
        }
        return nil
    }

    /// Buttons that receive clicks directly.
    var interactiveSubviews: [NSView] { [] }

    /// Frame of the title text in this row's coordinates, for inline rename.
    var titleFrame: NSRect { .zero }
    var titleFont: NSFont { SidebarStyle.titleFont }
    func setTitleHidden(_ hidden: Bool) {}

    func hoverChanged() { needsDisplay = true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    static func label(font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        return field
    }
}

// MARK: - Workspace

final class WorkspaceRowView: SidebarRowView {
    private let icon = SidebarIconView()
    private let title = SidebarRowView.label(font: SidebarStyle.titleFont, color: Palette.textPrimary)
    private let subtitle = SidebarRowView.label(font: SidebarStyle.subtitleFont, color: Palette.textSecondary)
    private let activity = ActivityIndicatorView()
    private let badge = UnreadBadgeView()
    private let rail = CALayer()
    let closeButton = SidebarIconButton(symbol: "xmark", pointSize: 9, weight: .bold, label: Strings.closeButton)

    private var hasSubtitle = false
    private var grouped = false
    private var groupColor: SidebarColor?
    /// Selected but not active (the active row sits on the shared pill).
    var isSecondarySelected = false { didSet { if isSecondarySelected != oldValue { needsDisplay = true } } }
    /// A tab dragged from a pane would move into this workspace.
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    var onClose: (() -> Void)?

    override init(key: SidebarRowKey) {
        super.init(key: key)
        rail.cornerRadius = 1
        layer?.addSublayer(rail)
        [icon, title, subtitle, activity, badge, closeButton].forEach(addSubview)
        closeButton.isHidden = true
        closeButton.onPress = { [weak self] in self?.onClose?() }
    }

    override var interactiveSubviews: [NSView] { [closeButton] }

    func configure(_ ws: SidebarWorkspace, row: SidebarRow, compact: Bool) {
        self.compact = compact
        grouped = row.group != nil
        groupColor = row.groupColor
        icon.configure(icon: ws.icon, title: ws.title)
        title.stringValue = ws.title
        title.font = ws.unread.isUnread ? SidebarStyle.titleUnreadFont : SidebarStyle.titleFont
        subtitle.stringValue = ws.subtitle ?? ""
        hasSubtitle = !(ws.subtitle ?? "").isEmpty
        activity.configure(ws.activity)
        badge.configure(ws.unread)
        toolTip = compact ? ws.title : nil
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(accessibilityText(ws))
        needsLayout = true
        needsDisplay = true
    }

    private func accessibilityText(_ ws: SidebarWorkspace) -> String {
        var parts = [ws.title]
        if let s = ws.subtitle, !s.isEmpty { parts.append(s) }
        switch ws.unread {
        case let .count(n) where n > 0: parts.append(Strings.unreadCount(n))
        case .dot: parts.append(Strings.unreadDot)
        default: break
        }
        switch ws.activity {
        case .running: parts.append(Strings.activityRunning)
        case .needsInput: parts.append(Strings.activityNeedsInput)
        case .error: parts.append(Strings.activityError)
        case .idle: break
        }
        return parts.joined(separator: ", ")
    }

    override var titleFrame: NSRect { title.frame }
    override var titleFont: NSFont { title.font ?? SidebarStyle.titleFont }
    private var renaming = false
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        title.isHidden = hidden
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.borderWidth = isDropTarget ? 1 : 0
        layer.borderColor = resolvedCGColor(Palette.focusRing.withAlphaComponent(0.6))
        if isDropTarget {
            layer.backgroundColor = resolvedCGColor(Palette.selectionFill)
        } else if isSecondarySelected {
            layer.backgroundColor = resolvedCGColor(SidebarStyle.secondarySelectionFill)
        } else if isHovered {
            layer.backgroundColor = resolvedCGColor(Palette.hoverFill)
        } else {
            layer.backgroundColor = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rail.backgroundColor = groupColor.map { SidebarStyle.color($0).withAlphaComponent(0.85).cgColor }
        rail.isHidden = !grouped
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if compact {
            let side = SidebarStyle.iconBox
            icon.frame = NSRect(x: (b.width - side) / 2, y: (b.height - side) / 2, width: side, height: side)
            [title, subtitle, closeButton].forEach { $0.isHidden = true }
            let bw = badge.state == .dot || badge.state == .none ? 8 : min(badge.preferredWidth, 22)
            badge.frame = NSRect(x: icon.frame.maxX - bw + 5, y: icon.frame.minY - 4, width: bw, height: badge.state == .dot ? 8 : 14)
            activity.frame = NSRect(x: icon.frame.maxX - 6, y: icon.frame.maxY - 6, width: 10, height: 10)
            rail.frame = CGRect(x: 2, y: 8, width: 2, height: b.height - 16)
            needsDisplay = true
            return
        }

        let indent: CGFloat = grouped ? SidebarStyle.groupIndent : 0
        rail.frame = CGRect(x: 5, y: 7, width: 2, height: b.height - 14)
        let iconX = 8 + indent
        let side = SidebarStyle.iconBox
        icon.frame = NSRect(x: iconX, y: (b.height - side) / 2, width: side, height: side)

        // Trailing cluster, right to left: close-or-badge, then activity.
        var trailing = b.width - 8
        let showClose = isHovered
        closeButton.isHidden = !showClose
        if showClose {
            closeButton.frame = NSRect(x: trailing - 18, y: (b.height - 18) / 2, width: 18, height: 18)
            trailing -= 18 + 6
            badge.isHidden = true
        } else if badge.state.isUnread {
            badge.isHidden = false
            let w = badge.preferredWidth
            let h: CGFloat = badge.state == .dot ? 8 : 16
            badge.frame = NSRect(x: trailing - w - (badge.state == .dot ? 4 : 0), y: (b.height - h) / 2, width: w, height: h)
            trailing = badge.frame.minX - 6
        }
        if activity.activity != .idle {
            activity.frame = NSRect(x: trailing - 12, y: (b.height - 12) / 2, width: 12, height: 12)
            trailing -= 12 + 6
        }

        let textX = icon.frame.maxX + 8
        let textW = max(0, trailing - textX)
        title.isHidden = renaming
        let th = ceil(title.intrinsicContentSize.height)
        if hasSubtitle {
            let sh = ceil(subtitle.intrinsicContentSize.height)
            let total = th + sh
            let top = (b.height - total) / 2
            title.frame = NSRect(x: textX, y: top, width: textW, height: th)
            subtitle.frame = NSRect(x: textX, y: top + th, width: textW, height: sh)
            subtitle.isHidden = false
        } else {
            title.frame = NSRect(x: textX, y: (b.height - th) / 2, width: textW, height: th)
            subtitle.isHidden = true
        }
        needsDisplay = true
    }
}

// MARK: - Group header

final class GroupHeaderRowView: SidebarRowView {
    private let chevron = NSImageView()
    private let folder = NSImageView()
    private let name = SidebarRowView.label(font: SidebarStyle.groupFont, color: Palette.textPrimary)
    private let count = SidebarRowView.label(font: SidebarStyle.subtitleFont, color: Palette.textSecondary)
    private let activity = ActivityIndicatorView()
    private let badge = UnreadBadgeView()
    private var color: SidebarColor = .gray
    private var collapsed = false
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }

    override init(key: SidebarRowKey) {
        super.init(key: key)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        chevron.contentTintColor = Palette.textSecondary
        chevron.wantsLayer = true
        folder.imageScaling = .scaleProportionallyDown
        count.alignment = .right
        [chevron, folder, name, count, activity, badge].forEach(addSubview)
    }

    func configure(_ group: SidebarGroup, row: SidebarRow, compact: Bool, animated: Bool) {
        self.compact = compact
        color = group.color
        name.stringValue = group.name
        count.stringValue = "\(row.childCount)"
        let wasCollapsed = collapsed
        collapsed = row.isCollapsed
        let symbol = collapsed ? "folder.fill" : "folder"
        folder.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: compact ? 14 : 11.5, weight: .semibold))
        folder.contentTintColor = SidebarStyle.color(group.color)
        activity.configure(collapsed ? group.aggregateActivity : .idle)
        let unread = group.unreadTotal
        badge.configure(collapsed && unread > 0 ? .count(unread) : .none)
        toolTip = compact ? group.name : nil
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel("\(group.name), \(Strings.groupCount(row.childCount))")
        setAccessibilityExpanded(!collapsed)
        needsLayout = true
        needsDisplay = true
        if wasCollapsed != collapsed { rotateChevron(animated: animated) } else { rotateChevron(animated: false) }
    }

    private func rotateChevron(animated: Bool) {
        let target: CGFloat = collapsed ? 0 : 90
        if animated && !Motion.reduceMotion {
            Motion.animate(Motion.layout) { chevron.animator().frameCenterRotation = target }
        } else {
            chevron.frameCenterRotation = target
        }
    }

    override var titleFrame: NSRect { name.frame }
    override var titleFont: NSFont { SidebarStyle.groupFont }
    private var renaming = false
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        name.isHidden = hidden
    }

    override func updateLayer() {
        guard let layer else { return }
        if isDropTarget {
            layer.backgroundColor = SidebarStyle.color(color).withAlphaComponent(0.18).cgColor
            layer.borderColor = SidebarStyle.color(color).withAlphaComponent(0.55).cgColor
            layer.borderWidth = 1
        } else {
            layer.backgroundColor = isHovered ? resolvedCGColor(Palette.hoverFill) : nil
            layer.borderWidth = 0
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        if compact {
            [chevron, name, count, badge, activity].forEach { $0.isHidden = true }
            folder.frame = NSRect(x: (b.width - 22) / 2, y: (b.height - 22) / 2, width: 22, height: 22)
            return
        }
        chevron.isHidden = false
        name.isHidden = renaming
        let chevronSide: CGFloat = 12
        let rotation = chevron.frameCenterRotation
        chevron.frameCenterRotation = 0
        chevron.frame = NSRect(x: 8, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        chevron.frameCenterRotation = rotation
        folder.frame = NSRect(x: chevron.frame.maxX + 4, y: (b.height - 16) / 2, width: 16, height: 16)

        var trailing = b.width - 10
        if badge.state.isUnread {
            badge.isHidden = false
            let w = badge.preferredWidth
            badge.frame = NSRect(x: trailing - w, y: (b.height - 16) / 2, width: w, height: 16)
            trailing = badge.frame.minX - 6
        } else {
            badge.isHidden = true
        }
        if activity.activity != .idle {
            activity.frame = NSRect(x: trailing - 12, y: (b.height - 12) / 2, width: 12, height: 12)
            trailing -= 18
        }
        let cw = ceil(count.attributedStringValue.size().width) + 4
        let ch = ceil(count.intrinsicContentSize.height)
        count.isHidden = !(isHovered || collapsed) || badge.state.isUnread
        if !count.isHidden {
            count.frame = NSRect(x: trailing - cw, y: (b.height - ch) / 2, width: cw, height: ch)
            trailing -= cw + 6
        }
        let nx = folder.frame.maxX + 6
        let nh = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: nx, y: (b.height - nh) / 2, width: max(0, trailing - nx), height: nh)
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }
}

// MARK: - Section header

final class SectionHeaderRowView: SidebarRowView {
    private let glyph = NSImageView()
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont, color: Palette.textSecondary)
    private let status = CALayer()
    private let chevron = NSImageView()
    private let separator = CALayer()
    let addButton = SidebarIconButton(symbol: "plus", pointSize: 10, weight: .semibold, label: Strings.newWorkspace)
    private var statusColor: NSColor?
    private var collapsed = false
    var onAdd: (() -> Void)?

    override init(key: SidebarRowKey) {
        super.init(key: key)
        glyph.contentTintColor = Palette.textSecondary
        chevron.contentTintColor = Palette.textSecondary
        status.cornerRadius = 3
        layer?.addSublayer(status)
        layer?.addSublayer(separator)
        [glyph, name, chevron, addButton].forEach(addSubview)
        addButton.onPress = { [weak self] in self?.onAdd?() }
    }

    override var interactiveSubviews: [NSView] { [addButton] }

    func configure(_ section: SidebarSection, row: SidebarRow, compact: Bool) {
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
            case (_, .connected): statusColor = .systemGreen
            case (_, .connecting): statusColor = .systemOrange
            case (_, .offline): statusColor = .systemGray
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
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        name.stringValue = title
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold))
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
        status.backgroundColor = statusColor?.cgColor
        status.isHidden = statusColor == nil || compact
        separator.backgroundColor = resolvedCGColor(Palette.separator)
        separator.isHidden = !compact
        CATransaction.commit()
        layer?.backgroundColor = nil
    }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if compact {
            [glyph, name, chevron, addButton].forEach { $0.isHidden = true }
            separator.frame = CGRect(x: 12, y: (b.height - 1) / 2, width: b.width - 24, height: 1)
            needsDisplay = true
            return
        }
        glyph.isHidden = false
        name.isHidden = false
        glyph.frame = NSRect(x: 10, y: (b.height - 14) / 2, width: 14, height: 14)
        var trailing = b.width - 6
        addButton.isHidden = !(isHovered && allowsAdd)
        if !addButton.isHidden {
            addButton.frame = NSRect(x: trailing - 20, y: (b.height - 20) / 2, width: 20, height: 20)
            trailing -= 22
        }
        chevron.isHidden = !(isHovered || collapsed)
        chevron.frame = NSRect(x: trailing - 14, y: (b.height - 12) / 2, width: 12, height: 12)
        trailing -= 18
        let nw = min(ceil(name.attributedStringValue.size().width) + 4, max(0, trailing - 30))
        let nh = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: glyph.frame.maxX + 6, y: (b.height - nh) / 2, width: nw, height: nh)
        status.frame = CGRect(x: name.frame.maxX + 6, y: b.height / 2 - 3, width: 6, height: 6)
        needsDisplay = true
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }
}

// MARK: - Empty section drop zone

final class EmptySectionRowView: SidebarRowView {
    private let label = SidebarRowView.label(font: SidebarStyle.subtitleFont, color: Palette.textSecondary)
    private let border = CAShapeLayer()

    override init(key: SidebarRowKey) {
        super.init(key: key)
        label.alignment = .center
        border.fillColor = nil
        border.lineWidth = 1
        border.lineDashPattern = [4, 3]
        layer?.addSublayer(border)
        addSubview(label)
    }

    func configure(pinned: Bool, compact: Bool) {
        self.compact = compact
        label.stringValue = pinned ? Strings.pinnedEmpty : Strings.sectionEmpty
        label.isHidden = compact
        needsLayout = true
    }

    override func updateLayer() {
        border.strokeColor = resolvedCGColor(Palette.separator.withAlphaComponent(0.25))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: SidebarStyle.rowCornerRadius, cornerHeight: SidebarStyle.rowCornerRadius, transform: nil)
        CATransaction.commit()
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 4, y: (bounds.height - h) / 2, width: bounds.width - 8, height: h)
        needsDisplay = true
    }
}
