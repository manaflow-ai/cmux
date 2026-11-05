import AppKit
import CmuxNextDesign
import QuartzCore

/// The parts a row's notification emphasis draws with (`SidebarNotificationEmphasis`): the leading
/// edge bar, the halo behind the trailing dot and the count pill. Each is made once per row and
/// hidden while the row has nothing for the person or the look is `standard`.
@MainActor
final class WorkspaceRowEmphasis {
    private(set) var style = SidebarNotificationEmphasis.standard
    private(set) var attention: WorkspaceRowAttention?
    let bar = NSView()
    let halo = CALayer()
    let pill = NotificationPillView()
    static let haloKey = "notification-halo"

    /// The look in force: nil when the row has nothing for the person or the look adds nothing.
    var active: SidebarNotificationEmphasis? {
        guard attention != nil, style != .standard else { return nil }
        return style
    }

    /// The pill stands in for the trailing dot: the bold-pill look with an unread count.
    var showsPill: Bool { active == .boldPill && (attention?.count ?? 0) > 0 }

    func update(style: SidebarNotificationEmphasis, attention: WorkspaceRowAttention?) {
        (self.style, self.attention) = (style, attention)
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
        label.font = .monospacedDigitSystemFont(ofSize: SidebarStyle.subtitleFont.pointSize, weight: TypeScale.emphasis)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, color: NSColor) {
        if label.stringValue != text { label.stringValue = text }
        layer?.backgroundColor = color.cgColor
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
    /// placeholder, or the `trailing` badge style that keeps the count).
    func configureEmphasis(_ badges: WorkspaceRowBadges?, style: SidebarNotificationEmphasis) {
        let attention = badges.flatMap(WorkspaceRowAttention.init)
        emphasis.update(style: style, attention: attention)
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
            if let attention, emphasis.showsPill { emphasis.pill.configure(text: attention.pillText, color: attention.color) }
        }
        // The pill stands in for the badge's dot; every other look keeps it.
        rowBadge.isHidden = rowBadge.states.isEmpty || emphasis.showsPill
        if active == .boldPill {
            title.font = NSFont.systemFont(ofSize: SidebarStyle.titleFont.pointSize, weight: TypeScale.emphasis)
        }
        configureHalo(active == .halo ? attention : nil)
        (needsDisplay, needsLayout) = (true, true)
    }

    /// The halo: a soft disc of the dot's color behind it, in the badge's own coordinates, breathing
    /// through the indicators' motion gate (still while loops are off or Reduce Motion is on).
    private func configureHalo(_ attention: WorkspaceRowAttention?) {
        let halo = emphasis.halo
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let attention, !rowBadge.isHidden, let host = rowBadge.layer else {
            halo.removeAnimation(forKey: WorkspaceRowEmphasis.haloKey)
            halo.isHidden = true
            return
        }
        if halo.superlayer !== host {
            halo.zPosition = -10
            host.insertSublayer(halo, at: 0)
        }
        let side = (SidebarStyle.statusDotSize * 2.5).rounded()
        let center = rowBadge.cellSide / 2
        halo.frame = CGRect(x: center - side / 2, y: center - side / 2, width: side, height: side)
        halo.cornerRadius = side / 2
        halo.backgroundColor = attention.color.withAlphaComponent(0.45).cgColor
        halo.isHidden = false
        if halo.animation(forKey: WorkspaceRowEmphasis.haloKey) == nil, let pulse = Motion.indicators.pulseAnimation(low: 0.15) {
            halo.add(pulse, forKey: WorkspaceRowEmphasis.haloKey)
        }
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

    /// Inside `updateLayer`'s theme scope: the bar's color, and the edge-bar look's wash, the fill
    /// a row at rest or hovered paints (selection and drop target keep their own fills).
    func emphasisFill(over fill: NSColor?) -> NSColor? {
        guard emphasis.active == .edgeBar, let attention = emphasis.attention else { return fill }
        let color = attention.color
        emphasis.bar.layer?.backgroundColor = color.cgColor
        guard !(isDropTarget || isSelected || isSecondarySelected) else { return fill }
        return color.withAlphaComponent(isHovered ? 0.2 : 0.13)
    }
}
