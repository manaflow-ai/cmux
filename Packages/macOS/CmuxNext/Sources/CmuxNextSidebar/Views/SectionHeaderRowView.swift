import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

final class SectionHeaderRowView: SidebarRowView {
    private let glyph = DecorativeImageView()
    /// The machine's own icon (`SidebarMachine.icon`) before the name; hidden without one.
    private let machineIcon = SidebarIconView()
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let status = CALayer()
    /// A machine on its way (connecting, reconnecting, installing) draws this spinner where the
    /// dot goes: working state is a spinner, never a pulsing dot. Its animation runs only while it
    /// shows (``StatusIndicatorView/spin(_:)``), and stops as the tone changes or the row is reused.
    private let spinner = StatusIndicatorView.spinner()
    /// "Update needed" after the status dot, for a machine whose cmux-tui
    /// is too old (the tooltip says why).
    private let badge = SidebarRowView.label(font: SidebarStyle.headerFont)
    private(set) var badgeText: String?
    private let chevron = DecorativeImageView()
    let addButton = SidebarIconButton(icon: .actionAdd, pointSize: { Metrics.smallIconSize - Metrics.space1 }, label: Strings.newWorkspace)
    /// The machine status dot's color, resolved in `updateLayer`; `working` draws the spinner.
    enum StatusTone { case success, attention, quiet, danger, working }
    private(set) var statusTone: StatusTone?
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
        layer?.addSublayer(status)
        [glyph, machineIcon, name, spinner, badge, chevron, addButton].forEach(addSubview)
        spinner.isHidden = true
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

    /// The header's mark for `machine` (``MachineLinkState``, the composer strip's same word):
    /// green once its daemon finished the handshake, a spinner on its way, red when down, grey
    /// when paused. This Mac draws nothing while connected.
    static func tone(_ machine: SidebarMachine, hostGroup: Bool) -> StatusTone? {
        switch (machine.kind, machine.status) {
        case (.local, .connected), (.local, .updateAvailable): return nil
        // An optional update is not the sidebar's to say (Lawrence 2026-10-21: "wtf is chief
        // update available"): the header reads as connected, its green dot as the composer
        // strip's, and the tooltip says it.
        default: break
        }
        return switch machine.status.linkState {
        case .connected: .success
        case .connecting: .working
        case .offline: .danger
        case .paused: .quiet
        case .attention: .attention
        }
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
        case .disconnected: Strings.statusDisconnected
        case .paused: Strings.statusPaused
        case .pausedIdle: Strings.statusPausedIdle
        case .pausing: Strings.statusPausing
        case .resuming: Strings.statusResuming
        case .deleting: Strings.statusDeleting
        }
    }

    /// The header's tooltip: what a bare status dot means in words ("Offline"). Where the words
    /// already show beside the dot (a remote group, an update state) or no dot draws (This Mac),
    /// only the detail an update state carries.
    static func statusToolTip(words: String, detail: String?, bareDot: Bool) -> String? {
        guard bareDot else { return detail }
        guard let detail, !detail.isEmpty else { return words }
        return words + " — " + detail
    }

    /// The status text beside a machine header's dot. A remote group (remote-groups-DESIGN.md slice 5)
    /// names every state, Connected and Offline included; another machine only what needs attention.
    static func statusText(_ status: SidebarMachine.Status, hostGroup: Bool) -> String? {
        switch status {
        case .connected: hostGroup ? Strings.statusConnected : nil
        case .connecting: hostGroup ? Strings.statusConnecting : nil
        case .offline: hostGroup ? Strings.statusOffline : nil
        // Never on the header: an optional update reads as connected (the tooltip says it).
        case .updateAvailable: hostGroup ? Strings.statusConnected : nil
        case .reconnecting: Strings.statusReconnecting
        case .updateRequired: Strings.statusUpdateRequired
        case .installRequired: Strings.statusInstallRequired
        case .installing: Strings.statusInstalling
        case .authFailed: Strings.statusAuthFailed
        case .unreachable: Strings.statusUnreachable
        case .failed: Strings.statusFailed
        case .disconnected: Strings.statusDisconnected
        case .paused: Strings.statusPaused
        case .pausedIdle: Strings.statusPausedIdle
        case .pausing: Strings.statusPausing
        case .resuming: Strings.statusResuming
        case .deleting: Strings.statusDeleting
        }
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
            fontSize: SidebarStyle.headerFont.pointSize, iconSize: SidebarStyle.leadingGlyphSide
        )
        guard needsConfigure(content) else { return }
        statusTip = nil
        cost = nil
        collapsed = row.isCollapsed
        isEmpty = content.isEmpty
        let symbol: IconName
        var title: String
        var ownIcon: WorkspaceIcon?
        switch section.kind {
        case .pinned:
            symbol = .statePinned
            title = Strings.pinned
            statusTone = nil
            badgeText = nil
            themedToolTip = nil
        case let .custom(custom):
            // A document section's own title (sidebar-v2); Pinned draws no header.
            symbol = custom.id == SidebarDocStore.pinnedSection ? .statePinned : .folder
            title = custom.title ?? ""
            statusTone = nil
            badgeText = nil
            themedToolTip = nil
        case let .machine(machine):
            switch machine.kind {
            case .local: symbol = .machineLocal
            case .cloud: symbol = .cloud
            case .ssh, .server: symbol = .machineRemote
            }
            title = machine.name
            ownIcon = machine.icon
            statusTone = Self.tone(machine, hostGroup: section.isHostGroup)
            let words = Self.statusWords(machine.status)
            badgeText = Self.statusText(machine.status, hostGroup: section.isHostGroup)
            statusTip = Self.statusToolTip(words: words, detail: machine.detail, bareDot: badgeText == nil && (statusTone != nil || machine.status == .updateAvailable))
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
            statusTone = nil
            badgeText = nil
            statusTip = nil
            cost = nil
            themedToolTip = nil
            setAccessibilityHelp(nil)
        }
        if section.machine == nil || row.titlesProjects { setAccessibilityLabel(title) }
        glyph.image = NSImage.icon(symbol, size: .iconRowSize(forLabelPointSize: SidebarStyle.headerFont.pointSize))
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
            glyph.setTint(Palette.textSecondary)
            chevron.setTint(Palette.textTertiary)
            status.backgroundColor = statusTone.flatMap(Self.color)?.cgColor
        }
        status.isHidden = statusTone == nil || statusTone == .working
        let working = statusTone == .working
        spinner.isHidden = !working
        spinner.spin(working)
        CATransaction.commit()
        // A click folds the section: hover shows the row's hover fill, like a workspace row (cx-qno.17).
        performWithTheme { paintFill(isHovered ? Palette.hoverFill : nil) }
    }

    // theme-scoped: called only inside performWithTheme
    private static func color(_ tone: StatusTone) -> NSColor? {
        switch tone {
        case .success: Palette.success
        case .attention: Palette.attention
        case .quiet: Palette.textTertiary
        case .danger: Palette.danger
        case .working: nil
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
        // A machine's own icon leads the name; without one the header stays text only.
        var nameX = SidebarStyle.horizontalInset
        if !machineIcon.isHidden {
            let side = SidebarStyle.leadingGlyphSide
            machineIcon.frame = NSRect(x: nameX, y: (b.height - side) / 2, width: side, height: side)
            nameX += side + Metrics.space2
        }
        // The add button keeps its slot, so the name never re-truncates on hover.
        // Section actions stay available at rest. Hiding them until hover made
        // the bottom of the sidebar flash as the pointer crossed a header.
        addButton.isHidden = !allowsAdd
        let control = SidebarStyle.controlSize
        if allowsAdd {
            addButton.frame = SidebarStyle.trailingColumnFrame(rowWidth: b.width, centerY: b.midY, side: control)
        }
        // The disclosure is a section control too; keep it stable instead of
        // making the header reflow when the pointer arrives.
        chevron.isHidden = isEmpty
        let chevronSide = Metrics.smallIconSize
        // Without the add button the chevron takes the trailing column, as a group header's does.
        chevron.frame = SidebarStyle.trailingColumnFrame(rowWidth: b.width, centerY: b.midY,
                                                         side: chevronSide, slot: allowsAdd ? 1 : 0)
        let trailing = chevron.frame.minX - Metrics.space2
        let nw = min(ceil(name.attributedStringValue.size().width) + Metrics.space2, max(0, trailing - nameX - Metrics.space5))
        let nh = ceil(name.intrinsicContentSize.height)
        // The label cell draws inside its frame: the text starts where row titles do.
        name.frame = NSRect(x: nameX - SidebarStyle.labelCellPadding, y: (b.height - nh) / 2, width: nw, height: nh)
        let dot = SidebarStyle.dotSize
        status.frame = CGRect(x: name.frame.maxX + Metrics.space2, y: (b.height - dot) / 2, width: dot, height: dot)
        status.cornerRadius = dot / 2
        // The spinner takes the dot's place, a little larger so its arc reads at the header's size.
        let spin = Metrics.smallIconSize - Metrics.space1
        spinner.frame = NSRect(x: status.frame.midX - spin / 2, y: (b.height - spin) / 2, width: spin, height: spin)
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
        // The running time and estimate move with the clock: a hover reads them now.
        if isHovered, cost != nil { themedToolTip = Self.machineToolTip(status: statusTip, cost: cost, now: Date()) }
        needsLayout = true
    }

    /// Whether the fold chevron shows (tests).
    var showsChevron: Bool { !chevron.isHidden }

    /// Whether the machine's own icon shows before the name (tests).
    var showsMachineIcon: Bool { !machineIcon.isHidden }
}

// MARK: - Empty section drop zone
