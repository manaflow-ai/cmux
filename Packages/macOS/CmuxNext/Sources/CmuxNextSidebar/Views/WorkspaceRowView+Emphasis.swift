import AppKit
import CmuxNextDesign
import QuartzCore

/// The parts a row's notification emphasis draws with (`SidebarNotificationEmphasis`): the leading
/// edge bar, the halo behind the trailing dot and the count pill. Each is made once per row and
/// hidden while the row has nothing for the person or the look is `standard`.
///
/// The halo's pulse follows what the status dots follow: the indicator config's loops switch
/// (animations, the indicators category, Reduce Motion; `StatusIndicatorAppearance`) and the
/// window's visibility (`SidebarListView.setWindowVisible`), and it keeps the shared phase
/// (`SpinnerClock`), so it never pulses on a hidden window or after motion was turned off.
@MainActor
final class WorkspaceRowEmphasis: StatusIndicatorConfigClient {
    private(set) var style = SidebarNotificationEmphasis.standard
    private(set) var attention: WorkspaceRowAttention?
    let bar = NSView()
    let halo = CALayer()
    let pill = NotificationPillView()
    static let haloKey = "notification-halo"
    /// The row's window shows (the list's occlusion walk sets it).
    var isWindowVisible = true {
        didSet { if isWindowVisible != oldValue { updateHaloMotion() } }
    }
    private var registered = false
    /// The badge shows one glyph (a stack of several keeps every chip; the pill never hides them).
    private(set) var singleGlyph = true

    /// The look in force: nil when the row has nothing for the person or the look adds nothing.
    var active: SidebarNotificationEmphasis? {
        guard attention != nil, style != .standard else { return nil }
        return style
    }

    /// The pill stands in for the trailing dot: the bold-pill look with an unread count.
    var showsPill: Bool { active == .boldPill && singleGlyph && (attention?.count ?? 0) > 0 }

    func update(style: SidebarNotificationEmphasis, attention: WorkspaceRowAttention?, singleGlyph: Bool) {
        (self.style, self.attention, self.singleGlyph) = (style, attention, singleGlyph)
    }

    /// Starts or stops the halo's pulse for what the person allows now; a hidden halo never pulses.
    func updateHaloMotion() {
        let animates = !halo.isHidden && halo.superlayer != nil && isWindowVisible
            && StatusIndicatorAppearance.shared.config.animatesLoops
        guard animates else {
            halo.removeAnimation(forKey: Self.haloKey)
            return
        }
        if !registered {
            registered = true
            StatusIndicatorAppearance.shared.register(self)
        }
        guard halo.animation(forKey: Self.haloKey) == nil,
              let pulse = Motion.indicators.pulseAnimation(low: 0.15), let period = Motion.indicators.period(.pulse) else { return }
        pulse.beginTime = SpinnerClock().beginTime(cycle: period)
        halo.add(pulse, forKey: Self.haloKey)
    }

    func statusIndicatorConfigDidChange(_ config: StatusIndicatorConfig) {
        updateHaloMotion()
    }
}

/// A filled capsule with the unread count, white on the badge's color (the bold-pill look).
final class NotificationPillView: NSView {
    private let label = NSTextField(labelWithString: "")
    static var height: CGFloat { SidebarStyle.badgeHeight + 2 }
    static let pad: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String) {
        // The font follows the sidebar's text size and density, read on every configure.
        let font = NSFont.monospacedDigitSystemFont(ofSize: SidebarStyle.subtitleFont.pointSize, weight: TypeScale.emphasis)
        if label.font != font { label.font = font }
        if label.stringValue != text { label.stringValue = text }
        needsLayout = true
    }

    var preferredWidth: CGFloat {
        max(Self.height, ceil(label.intrinsicContentSize.width) + 2 * Self.pad)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h)
    }
}

extension WorkspaceRowView {
    /// Sets the row's emphasis after its badges (`configureBadges`); nil `badges` clears it (a
    /// placeholder, or the `trailing` badge style that keeps the count). `leading` is the badge's
    /// first glyph: the emphasis says what that glyph says, so a working spinner the badge leads
    /// with is never covered by a blue halo or hidden behind a pill.
    func configureEmphasis(_ badges: WorkspaceRowBadges?, leading: StatusIndicatorState? = nil, style: SidebarNotificationEmphasis) {
        let attention = badges.flatMap { WorkspaceRowAttention($0, leading: leading) }
        emphasis.update(style: style, attention: attention, singleGlyph: rowBadge.states.count <= 1)
        let active = emphasis.active
        if active == .edgeBar, emphasis.bar.superview == nil {
            emphasis.bar.wantsLayer = true
            emphasis.bar.layer?.cornerRadius = Self.colorRailWidth / 2
            addSubview(emphasis.bar, positioned: .above, relativeTo: colorRail.superview == nil ? nil : colorRail)
        }
        emphasis.bar.isHidden = active != .edgeBar
        if active == .boldPill || emphasis.pill.superview != nil {
            if emphasis.pill.superview == nil { addSubview(emphasis.pill) }
            emphasis.pill.isHidden = !emphasis.showsPill
            if let attention, emphasis.showsPill { emphasis.pill.configure(text: attention.pillText) }
            // The badge's summary ("3 unread, Needs you") stays under the pointer when the pill stands in for it.
            emphasis.pill.themedToolTip = emphasis.showsPill ? rowBadge.themedToolTip : nil
        }
        // The pill stands in for the badge's dot; every other look keeps it.
        rowBadge.isHidden = rowBadge.states.isEmpty || emphasis.showsPill
        if active == .boldPill {
            title.font = NSFont.systemFont(ofSize: SidebarStyle.titleFont.pointSize, weight: TypeScale.emphasis)
        }
        configureHalo(active == .halo)
        (needsDisplay, needsLayout) = (true, true)
    }

    /// The halo: a soft disc behind the badge's first glyph (the dot), in the badge's own
    /// coordinates; its color is set in `updateLayer` (`paintEmphasis`) under the row's theme.
    private func configureHalo(_ shows: Bool) {
        let halo = emphasis.halo
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if shows, !rowBadge.isHidden, let host = rowBadge.layer {
            if halo.superlayer !== host {
                halo.zPosition = -10
                host.insertSublayer(halo, at: 0)
            }
            let side = (SidebarStyle.statusDotSize * 2.5).rounded()
            let center = rowBadge.cellSide / 2
            halo.frame = CGRect(x: center - side / 2, y: center - side / 2, width: side, height: side)
            halo.cornerRadius = side / 2
            halo.isHidden = false
        } else {
            halo.isHidden = true
        }
        emphasis.updateHaloMotion()
    }

    /// The edge bar's place: where a `leftRail` color's bar goes, over it.
    func layoutEmphasis(in bounds: NSRect) {
        guard !emphasis.bar.isHidden else { return }
        let inset = Metrics.space1, indent = CGFloat(treeDepth) * SidebarStyle.treeIndent
        emphasis.bar.frame = NSRect(x: bounds.minX + indent + inset, y: bounds.minY + inset,
                                    width: Self.colorRailWidth, height: max(0, bounds.height - 2 * inset))
    }

    /// The pill on the trailing column, where the dot would be; nil when it does not show.
    func layoutEmphasisPill(column: CGFloat, cy: CGFloat) -> NSView? {
        guard emphasis.showsPill else { return nil }
        let pill = emphasis.pill, h = NotificationPillView.height, w = pill.preferredWidth
        let scale = window?.backingScaleFactor ?? 1
        pill.frame = NSRect(x: SidebarStyle.pixelSnapped(column + h / 2 - w, scale: scale),
                            y: SidebarStyle.pixelSnapped(cy - h / 2, scale: scale), width: w, height: h)
        return pill
    }

    /// Inside `updateLayer`'s theme scope, so every part takes the theme's status color as the badge's
    /// dot does: the bar, the pill and the halo; returns the fill the row paints. The edge-bar look's
    /// wash replaces only the plain fills (rest and hover): selection, on screen, drop target and a
    /// workspace color's fill keep their own.
    func paintEmphasis(over fill: NSColor?, colorFilled: Bool) -> NSColor? {
        guard let active = emphasis.active, let attention = emphasis.attention else { return fill }
        let color = attention.color
        switch active {
        case .standard: return fill
        case .boldPill:
            emphasis.pill.layer?.backgroundColor = color.cgColor
            return fill
        case .halo:
            emphasis.halo.backgroundColor = color.withAlphaComponent(0.45).cgColor
            return fill
        case .edgeBar:
            emphasis.bar.layer?.backgroundColor = color.cgColor
            guard !colorFilled, !(isDropTarget || isSelected || isSecondarySelected || isOnScreen) else { return fill }
            let hovered = isHovered && !isPlaceholderRow && DesignSettings.shared.showsHoverFills
            return color.withAlphaComponent(hovered ? 0.2 : 0.13)
        }
    }
}
