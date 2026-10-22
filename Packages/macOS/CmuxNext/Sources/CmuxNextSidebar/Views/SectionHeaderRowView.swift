import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

final class SectionHeaderRowView: SidebarRowView {
    /// A machine's form glyph (`SidebarMachineForm`: cloud, Mac mini, laptop, server) before the
    /// name, in place of the old status dot; hidden when the machine has its own icon.
    private let glyph = DecorativeImageView()
    /// The form `glyph` draws; nil while it is hidden (tests).
    private(set) var leadingGlyph: IconName?
    /// The machine's own icon (`SidebarMachine.icon`) before the name; hidden without one.
    private let machineIcon = SidebarIconView()
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    /// The machine's state in words after the name ("Offline", "Update needed"), never "Connected";
    /// the tooltip says why.
    private let badge = SidebarRowView.label(font: SidebarStyle.headerFont)
    private var badgeText: String?
    private let chevron = DecorativeImageView()
    let addButton = SidebarIconButton(icon: .actionAdd, pointSize: { Metrics.smallIconSize - Metrics.space1 }, label: Strings.newWorkspace)
    /// The machine is not connected: its glyph, icon and name draw dimmed.
    private(set) var isDimmed = false
    private var collapsed = false
    /// No workspaces: nothing to fold, so hover shows no chevron (cx-odqn).
    private var isEmpty = false
    /// The status part of the tooltip, and a Cloud machine's cost, kept so a
    /// hover rewrites the running time and estimate as of that moment.
    private var statusTip: String?
    private var cost: SidebarMachine.Cost?
    var onAdd: (() -> Void)?

    required init(key: SidebarRowKey) {
        super.init(key: key)
        [glyph, machineIcon, name, badge, chevron, addButton].forEach(addSubview)
        // The header's label and AXExpanded say what the glyph and chevron draw.
        addButton.onPress = { [weak self] in self?.onAdd?() }
    }

    override var interactiveSubviews: [NSView] { [addButton] }

    private struct Content: Hashable {
        // The section's kind, not its nodes: comparing 1,000 children per
        // reload would defeat the point.
        var kind: SidebarSection.Kind
        var isHostGroup: Bool
        var titlesProjects: Bool
        var collapsed: Bool
        var isEmpty: Bool
        var fontSize: CGFloat
        var iconSize: CGFloat
    }

    /// A machine's state in words, for the header's label and the dot's tooltip.
    static func statusWords(_ status: SidebarMachine.Status) -> String {
        switch status {
        case .connected: Strings.statusConnected
        case .connecting: Strings.statusConnecting
        case .reconnecting: Strings.statusReconnecting
        case .offline: Strings.statusOffline
        case .updateAvailable: Strings.statusUpdateAvailable
        case .updateRequired: Strings.statusUpdateRequired
        case .installRequired: Strings.statusInstallRequired
        case .installing: Strings.statusInstalling
        case .authFailed: Strings.statusAuthFailed
        case .unreachable: Strings.statusUnreachable
        case .failed: Strings.statusFailed
        case .paused: Strings.statusPaused
        case .pausedIdle: Strings.statusPausedIdle
        }
    }

    /// The header's tooltip: the state in words when no words show beside the name (a connected
    /// machine other than This Mac); where the words show, or for This Mac, only the detail an
    /// update state carries.
    static func statusToolTip(words: String, detail: String?, bareDot: Bool) -> String? {
        guard bareDot else { return detail }
        guard let detail, !detail.isEmpty else { return words }
        return words + " — " + detail
    }

    /// The words after a machine header's name. Minimal (remote-groups-per-machine-DESIGN.md R1): a
    /// connected machine says nothing, and every other state says itself, remote group or not, now
    /// that no status dot draws. `hostGroup` is kept for callers; both kinds follow one rule.
    static func statusText(_ status: SidebarMachine.Status, hostGroup _: Bool) -> String? {
        status == .connected ? nil : statusWords(status)
    }

    /// The header's tooltip: the status words or detail, then a Cloud
    /// machine's cost and the account's cap (`SidebarMachine.Cost.lines`) as of `now`.
    static func machineToolTip(status: String?, cost: SidebarMachine.Cost?, now: Date) -> String? {
        let lines = [status].compactMap { $0?.isEmpty == false ? $0 : nil } + (cost?.lines(now: now) ?? [])
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func configure(_ section: SidebarSection, row: SidebarRow) {
        let content = Content(
            kind: section.kind, isHostGroup: section.isHostGroup, titlesProjects: row.titlesProjects, collapsed: row.isCollapsed, isEmpty: section.nodes.isEmpty,
            fontSize: SidebarStyle.headerFont.pointSize, iconSize: Metrics.smallIconSize
        )
        guard needsConfigure(content) else { return }
        statusTip = nil
        cost = nil
        collapsed = row.isCollapsed
        isEmpty = content.isEmpty
        var symbol: IconName?
        var title: String
        var ownIcon: WorkspaceIcon?
        var dimmed = false
        switch section.kind {
        case .pinned:
            symbol = .statePinned
            title = Strings.pinned
            badgeText = nil
            themedToolTip = nil
        case let .custom(custom):
            // A document section's own title (sidebar-v2); Pinned draws no header.
            symbol = custom.id == SidebarDocStore.pinnedSection ? .statePinned : .folder
            title = custom.title ?? ""
            badgeText = nil
            themedToolTip = nil
        case let .machine(machine):
            symbol = SidebarMachineForm(machine).icon
            title = machine.name
            ownIcon = machine.icon
            dimmed = machine.status != .connected && machine.status != .updateAvailable
            let words = Self.statusWords(machine.status)
            badgeText = Self.statusText(machine.status, hostGroup: section.isHostGroup)
            let saysNothing = badgeText == nil && !(machine.kind == .local && machine.status == .connected)
            statusTip = Self.statusToolTip(words: words, detail: machine.detail, bareDot: saysNothing)
            cost = machine.kind == .cloud ? machine.cost : nil
            themedToolTip = Self.machineToolTip(status: statusTip, cost: cost, now: Date())
            setAccessibilityLabel(machine.name + ", " + words)
            setAccessibilityHelp(cost == nil ? machine.detail : themedToolTip)
        }
        // The only machine needs no name or status: the header heads the
        // workspace list, apart from the destinations above it.
        if row.titlesProjects {
            title = Strings.projects
            ownIcon = nil
            symbol = nil
            dimmed = false
            badgeText = nil
            statusTip = nil
            cost = nil
            themedToolTip = nil
            setAccessibilityHelp(nil)
        }
        if section.machine == nil || row.titlesProjects { setAccessibilityLabel(title) }
        // The pinned and custom headers keep text only; a machine draws its form unless it has its own icon.
        if section.machine == nil || ownIcon != nil { symbol = nil }
        leadingGlyph = symbol
        isDimmed = dimmed
        glyph.image = symbol.map { NSImage.icon($0, size: .iconRowSize(forLabelPointSize: SidebarStyle.headerFont.pointSize)) }
        machineIcon.configure(icon: ownIcon)
        name.setString(title)
        name.setFont(SidebarStyle.headerFont)
        badge.setString(badgeText ?? "")
        badge.setFont(SidebarStyle.headerFont)
        chevron.image = SidebarStyle.chevron(collapsed: collapsed)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityExpanded(!collapsed)
        let sectionID = switch section.id {
        case .pinned: "pinned"
        case let .machine(machine): "machine.\(machine.rawValue)"
        case let .custom(custom): "custom.\(custom)"
        }
        setAccessibilityIdentifier("cmux.sidebar.section.\(sectionID)")
        addButton.setAccessibilityIdentifier("cmux.sidebar.section.\(sectionID).newWorkspace")
        addButton.isHidden = true
        needsLayout = true
        needsDisplay = true
    }

    var allowsAdd = true

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        performWithTheme {
            name.setColor(Palette.textTertiary)
            badge.setColor(Palette.textTertiary)
            glyph.setTint(Palette.textTertiary)
            chevron.setTint(Palette.textTertiary)
        }
        // Not connected: the machine's glyph, icon and name step back; the words say why.
        let alpha: CGFloat = isDimmed ? 0.55 : 1
        [glyph, machineIcon, name].forEach { $0.alphaValue = alpha }
        CATransaction.commit()
        // A click folds the section: hover shows the row's hover fill, like a workspace row (cx-qno.17).
        performWithTheme { paintFill(isHovered ? Palette.hoverFill : nil) }
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // A machine's icon leads the name: its own icon, else its form glyph (remote-groups-per-machine
        // R1). Pinned and custom headers stay text only, the name aligned with row titles.
        glyph.isHidden = leadingGlyph == nil
        name.isHidden = false
        var nameX = SidebarStyle.horizontalInset
        let side = Metrics.smallIconSize
        if !machineIcon.isHidden {
            machineIcon.frame = NSRect(x: nameX, y: (b.height - side) / 2, width: side, height: side)
            nameX += side + Metrics.space2
        } else if !glyph.isHidden {
            glyph.frame = NSRect(x: nameX, y: (b.height - side) / 2, width: side, height: side)
            nameX += side + Metrics.space2
        }
        var trailing = b.width - SidebarStyle.horizontalInset
        // The add button keeps its slot, so the name never re-truncates on hover.
        // Section actions stay available at rest. Hiding them until hover made
        // the bottom of the sidebar flash as the pointer crossed a header.
        addButton.isHidden = !allowsAdd
        let control = SidebarStyle.controlSize
        if allowsAdd {
            addButton.frame = NSRect(x: trailing - control, y: (b.height - control) / 2, width: control, height: control)
            trailing -= control + Metrics.space1
        }
        // The disclosure is a section control too; keep it stable instead of
        // making the header reflow when the pointer arrives.
        chevron.isHidden = isEmpty
        let chevronSide = Metrics.smallIconSize
        chevron.frame = NSRect(x: trailing - chevronSide, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        trailing -= chevronSide + Metrics.space2
        let nw = min(ceil(name.attributedStringValue.size().width) + Metrics.space2, max(0, trailing - nameX - Metrics.space5))
        let nh = ceil(name.intrinsicContentSize.height)
        // The label cell draws inside its frame: the text starts where row titles do.
        name.frame = NSRect(x: nameX - SidebarStyle.labelCellPadding, y: (b.height - nh) / 2, width: nw, height: nh)
        badge.isHidden = badgeText == nil
        if !badge.isHidden {
            let bx = name.frame.maxX + Metrics.space2
            let bw = min(ceil(badge.attributedStringValue.size().width) + Metrics.space2, max(0, trailing - bx))
            let bh = ceil(badge.intrinsicContentSize.height)
            badge.frame = NSRect(x: bx, y: (b.height - bh) / 2, width: bw, height: bh)
        }
        needsDisplay = true
    }

    override func hoverChanged() {
        super.hoverChanged()
        // The running time and estimate move with the clock: a hover reads them now.
        if isHovered, cost != nil { themedToolTip = Self.machineToolTip(status: statusTip, cost: cost, now: Date()) }
        needsLayout = true
    }

    /// Whether the fold chevron shows (tests).
    var showsChevron: Bool { !chevron.isHidden }

    /// Whether the machine's own icon shows before the name (tests).
    var showsMachineIcon: Bool { !machineIcon.isHidden }

    /// Whether a status color dot draws (tests): never; the machine's icon took its place.
    var showsStatusDot: Bool { false }
}

// MARK: - Empty section drop zone
