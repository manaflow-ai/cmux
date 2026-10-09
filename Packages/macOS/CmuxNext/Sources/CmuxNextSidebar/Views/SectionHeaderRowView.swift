import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

final class SectionHeaderRowView: SidebarRowView {
    private let glyph = NSImageView()
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let status = CALayer()
    /// "Update needed" after the status dot, for a machine whose cmux-tui
    /// is too old (the tooltip says why).
    private let badge = SidebarRowView.label(font: SidebarStyle.headerFont)
    private var badgeText: String?
    private let chevron = NSImageView()
    let addButton = SidebarIconButton(symbol: "plus", pointSize: { Metrics.smallIconSize - Metrics.space1 }, weight: .semibold, label: Strings.newWorkspace)
    /// The machine status dot's color, resolved in `updateLayer`.
    private enum StatusTone { case success, attention, quiet, danger }
    private var statusTone: StatusTone?
    private var collapsed = false
    /// No workspaces: nothing to fold, so hover shows no chevron (cx-odqn).
    private var isEmpty = false
    var onAdd: (() -> Void)?

    required init(key: SidebarRowKey) {
        super.init(key: key)
        layer?.addSublayer(status)
        [glyph, name, badge, chevron, addButton].forEach(addSubview)
        addButton.onPress = { [weak self] in self?.onAdd?() }
    }

    override var interactiveSubviews: [NSView] { [addButton] }

    private struct Content: Hashable {
        // The section's kind, not its nodes: comparing 1,000 children per
        // reload would defeat the point.
        var kind: SidebarSection.Kind
        var titlesProjects: Bool
        var collapsed: Bool
        var isEmpty: Bool
        var fontSize: CGFloat
        var iconSize: CGFloat
    }

    func configure(_ section: SidebarSection, row: SidebarRow) {
        let content = Content(
            kind: section.kind, titlesProjects: row.titlesProjects, collapsed: row.isCollapsed, isEmpty: section.nodes.isEmpty,
            fontSize: SidebarStyle.headerFont.pointSize, iconSize: Metrics.smallIconSize
        )
        guard needsConfigure(content) else { return }
        collapsed = row.isCollapsed
        isEmpty = content.isEmpty
        let symbol: IconName
        var title: String
        switch section.kind {
        case .pinned:
            symbol = .statePinned
            title = Strings.pinned
            statusTone = nil
            badgeText = nil
            toolTip = nil
        case let .machine(machine):
            switch machine.kind {
            case .local: symbol = .machineLocal
            case .cloud: symbol = .cloud
            case .ssh, .server: symbol = .machineRemote
            }
            title = machine.name
            switch (machine.kind, machine.status) {
            case (.local, .connected): statusTone = nil
            case (_, .connected), (_, .updateAvailable): statusTone = .success
            case (_, .connecting), (_, .installing), (_, .installRequired): statusTone = .attention
            case (_, .offline): statusTone = .quiet
            case (_, .updateRequired), (_, .authFailed), (_, .unreachable): statusTone = .danger
            }
            var label = machine.name
            switch machine.status {
            case .connected: label += ", " + Strings.statusConnected
            case .connecting: label += ", " + Strings.statusConnecting
            case .offline: label += ", " + Strings.statusOffline
            case .updateAvailable: label += ", " + Strings.statusUpdateAvailable
            case .updateRequired: label += ", " + Strings.statusUpdateRequired
            case .installRequired: label += ", " + Strings.statusInstallRequired
            case .installing: label += ", " + Strings.statusInstalling
            case .authFailed: label += ", " + Strings.statusAuthFailed
            case .unreachable: label += ", " + Strings.statusUnreachable
            }
            badgeText = switch machine.status {
            case .updateAvailable: Strings.statusUpdateAvailable
            case .updateRequired: Strings.statusUpdateRequired
            case .installRequired: Strings.statusInstallRequired
            case .installing: Strings.statusInstalling
            case .authFailed: Strings.statusAuthFailed
            case .unreachable: Strings.statusUnreachable
            default: nil
            }
            toolTip = machine.detail
            setAccessibilityLabel(label)
            setAccessibilityHelp(machine.detail)
        }
        // The only machine needs no name or status: the header heads the
        // workspace list, apart from the destinations above it.
        if row.titlesProjects {
            title = Strings.projects
            statusTone = nil
            badgeText = nil
            toolTip = nil
            setAccessibilityHelp(nil)
        }
        if section.kind == .pinned || row.titlesProjects { setAccessibilityLabel(title) }
        glyph.image = NSImage.icon(symbol, size: .iconRowSize(forLabelPointSize: SidebarStyle.headerFont.pointSize))
        name.stringValue = title
        name.font = SidebarStyle.headerFont
        badge.stringValue = badgeText ?? ""
        badge.font = SidebarStyle.headerFont
        chevron.image = SidebarStyle.chevron(collapsed: collapsed)
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
        performWithTheme {
            name.textColor = Palette.textTertiary
            badge.textColor = Palette.textTertiary
            glyph.contentTintColor = Palette.textSecondary
            chevron.contentTintColor = Palette.textTertiary
            status.backgroundColor = statusTone.map(Self.color)?.cgColor
        }
        status.isHidden = statusTone == nil
        CATransaction.commit()
        layer?.backgroundColor = nil
    }

    // theme-scoped: called only inside performWithTheme
    private static func color(_ tone: StatusTone) -> NSColor {
        switch tone {
        case .success: Palette.success
        case .attention: Palette.attention
        case .quiet: Palette.textTertiary
        case .danger: Palette.danger
        }
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Quiet text header: no glyph, the name aligns with row titles.
        glyph.isHidden = true
        name.isHidden = false
        let nameX = SidebarStyle.horizontalInset
        var trailing = b.width - Metrics.space2
        // The add button keeps its slot, so the name never re-truncates on hover.
        addButton.isHidden = !(isHovered && allowsAdd)
        let control = SidebarStyle.controlSize
        if allowsAdd {
            addButton.frame = NSRect(x: trailing - control, y: (b.height - control) / 2, width: control, height: control)
            trailing -= control + Metrics.space1
        }
        chevron.isHidden = !((isHovered && !isEmpty) || collapsed)
        let chevronSide = Metrics.smallIconSize
        chevron.frame = NSRect(x: trailing - chevronSide, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        trailing -= chevronSide + Metrics.space2
        let nw = min(ceil(name.attributedStringValue.size().width) + Metrics.space2, max(0, trailing - nameX - Metrics.space5))
        let nh = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: nameX, y: (b.height - nh) / 2, width: nw, height: nh)
        let dot = SidebarStyle.dotSize
        status.frame = CGRect(x: name.frame.maxX + Metrics.space2, y: (b.height - dot) / 2, width: dot, height: dot)
        status.cornerRadius = dot / 2
        badge.isHidden = badgeText == nil
        if !badge.isHidden {
            let bx = status.frame.maxX + Metrics.space2
            let bw = min(ceil(badge.attributedStringValue.size().width) + Metrics.space2, max(0, trailing - bx))
            let bh = ceil(badge.intrinsicContentSize.height)
            badge.frame = NSRect(x: bx, y: (b.height - bh) / 2, width: bw, height: bh)
        }
        needsDisplay = true
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }

    var nameFrame: NSRect { name.frame }
    /// Whether the fold chevron shows (tests).
    var showsChevron: Bool { !chevron.isHidden }
}

// MARK: - Empty section drop zone
