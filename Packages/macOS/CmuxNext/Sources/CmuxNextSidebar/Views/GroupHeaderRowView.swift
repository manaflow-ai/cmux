import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// Group header as the Chrome tab group header bar (cx-rcby, Lawrence
/// 2026-10-08: "make sure for groups we pixel match this", "but with our
/// smaller height"): one full-width rounded bar filled with the group's
/// color (light gray for none) with the name in dark regular type, a more
/// (⋮) button on hover and the collapse chevron at the right edge. Radius,
/// padding, type and glyphs scale with the row height (the sidebar density
/// setting). No member count: a collapsed group shows its members' activity
/// and unread total in the bar. The name, the more button and a right-click
/// open the group editor; the chevron and the rest of the bar collapse.
final class GroupHeaderRowView: SidebarRowView {
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let chevron = NSImageView()
    private let activity = StatusIndicatorView()
    private let badge = UnreadBadgeView()
    private let pin = NSImageView()
    /// The group's icon inside its chip, before the name (`workspace-group-icon-v1`).
    let glyph = SidebarIconView()
    private let pill = CALayer()
    /// The members' bar starts under the chip (the members' rows continue it).
    private let connector = CALayer()
    /// The more button (⋮): the group editor. Shows on hover and while the editor is open.
    let moreButton = SidebarIconButton(symbol: "ellipsis", pointSize: { Metrics.smallIconSize - Metrics.space1 }, weight: .bold,
                                       label: GroupEditorStrings.more)
    private var pinned = false
    private var hasIcon = false
    private var color: GroupColor = .grey
    private var collapsed = false
    private var hasMembers = false
    private var chevronFrame: CGRect = .zero
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    /// Arrow keys stopped here (`SidebarListView+GroupKeys`): a focus ring, not a selection.
    var isKeyboardFocused = false { didSet { if isKeyboardFocused != oldValue { needsDisplay = true } } }
    /// The group editor is open for this group: the chip stays in its hover look.
    var isEditing = false { didSet { if isEditing != oldValue { needsLayout = true; needsDisplay = true } } }
    var onMore: (() -> Void)?

    override var interactiveSubviews: [NSView] { [moreButton] }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        layer?.addSublayer(connector)
        layer?.addSublayer(pill)
        for sublayer in [pill, connector] { sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()] }
        glyph.drawsUncoloredSymbolAsText = true
        // The more glyph stands upright (⋮), like the Chrome chip's.
        moreButton.image = Self.verticalEllipsis()
        [glyph, name, pin, chevron, activity, badge, moreButton].forEach(addSubview)
        moreButton.onPress = { [weak self] in self?.onMore?() }
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: GroupEditorStrings.editor) { [weak self] in
            self?.onMore?()
            return self?.onMore != nil
        }])
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        isDropTarget = false
        isKeyboardFocused = false
        isEditing = false
        collapsed = false
        onMore = nil
    }

    private struct Content: Hashable {
        var group: SidebarGroup
        var childCount: Int
        var collapsed: Bool
        var fontSize: CGFloat
    }

    func configure(_ group: SidebarGroup, row: SidebarRow, animated: Bool) {
        let content = Content(group: group, childCount: row.childCount, collapsed: row.isCollapsed, fontSize: SidebarStyle.headerFont.pointSize)
        guard needsConfigure(content) else { return }
        color = group.color
        name.stringValue = group.name
        pinned = group.isPinned
        hasIcon = group.icon != nil
        glyph.configure(icon: group.icon)
        pin.image = pinned ? NSImage.icon(.statePinned, size: Metrics.smallIconSize) : nil
        collapsed = row.isCollapsed
        hasMembers = row.childCount > 0
        chevron.image = Self.chevronImage(collapsed: collapsed)
        moreButton.image = Self.verticalEllipsis()
        activity.configure(collapsed ? group.aggregateActivity : .idle)
        let unread = group.unreadTotal
        badge.configure(collapsed && unread > 0 ? .count(unread) : .none)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel("\(group.name), \(Strings.groupCount(row.childCount))")
        setAccessibilityHelp(collapsed ? GroupEditorStrings.expand : GroupEditorStrings.collapse)
        setAccessibilityExpanded(!collapsed)
        needsLayout = true
        needsDisplay = true
    }

    /// Three dots stacked, the Chrome chip's more glyph, as a template image.
    private static func verticalEllipsis() -> NSImage {
        let side = Metrics.smallIconSize, dot = max(2, side / 6)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            for i in 0..<3 {
                let y = rect.midY + CGFloat(i - 1) * dot * 2.2 - dot / 2
                NSBezierPath(ovalIn: NSRect(x: rect.midX - dot / 2, y: y, width: dot, height: dot)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func chevronImage(collapsed: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize - Metrics.space2, weight: .bold)
        return NSImage(systemSymbolName: collapsed ? "chevron.down" : "chevron.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    override var titleFrame: NSRect { name.frame }
    /// The group chip (`GroupLabelBandTests`): a click here opens the editor.
    var labelFrame: NSRect { pill.frame }
    /// The width the name needs to draw whole (`GroupLabelBandTests`).
    var titleIntrinsicWidth: CGFloat {
        let font = name.font ?? SidebarStyle.headerFont
        let text = ceil((name.stringValue as NSString).size(withAttributes: [.font: font]).width)
        return max(ceil(name.intrinsicContentSize.width), text + 2 * Metrics.space2)
    }
    /// The group's name and icon: a click here opens the editor; the rest
    /// of the bar and the chevron collapse (the Chrome header toggles).
    var nameHitFrame: NSRect {
        let start = hasIcon ? glyph.frame.minX : name.frame.minX
        return NSRect(x: start - Metrics.space2, y: 0, width: name.frame.maxX - start + 2 * Metrics.space2, height: bounds.height)
    }
    var labelFill: CGColor? { pill.isHidden ? nil : pill.backgroundColor }
    override var titleFont: NSFont { name.font ?? SidebarStyle.headerFont }
    private var renaming = false
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        name.isHidden = hidden
    }

    /// Whether the more button shows: on hover, and while the editor is open.
    private var showsMore: Bool { isHovered || isEditing }

    override func updateLayer() {
        performWithTheme {
            // Dark text and glyphs on the light or colored bar (the Chrome tab group header).
            let ink = GroupColor.headerInk
            name.textColor = ink
            pin.contentTintColor = ink.withAlphaComponent(0.7)
            chevron.contentTintColor = ink
            moreButton.contentTintColor = ink
            var fill = color.headerFill
            if isHovered || isEditing { fill = fill.blended(withFraction: 0.08, of: .black) ?? fill }
            if isDropTarget { fill = fill.blended(withFraction: 0.16, of: .black) ?? fill }
            pill.backgroundColor = fill.cgColor
            pill.borderWidth = isDropTarget ? Metrics.dividerThickness * 1.5 : 0
            pill.borderColor = ink.withAlphaComponent(0.5).cgColor
            // A collapsed group that holds the selected workspace paints the selection fill around its bar.
            paintFill(isSelected ? Palette.selectionFill : nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.borderColor = Palette.focusRing.cgColor
            layer?.borderWidth = isKeyboardFocused ? Metrics.dividerThickness * 1.5 : 0
            layer?.cornerRadius = SidebarStyle.rowCornerRadius
            CATransaction.commit()
        }
    }

    /// The chevron and the space around it: a click here collapses or expands.
    var disclosureFrame: NSRect { chevronFrame.insetBy(dx: -Metrics.space1, dy: -Metrics.space2) }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // One full-width rounded bar (the Chrome tab group header) whose
        // radius, padding, type and glyphs scale with the row height
        // (the sidebar density: compact 24, comfortable 32 pt).
        let barHeight = SidebarStyle.groupHeaderBarHeight(rowHeight: b.height)
        let pad = (barHeight * 0.62).rounded()
        name.isHidden = renaming
        name.font = SidebarStyle.groupHeaderFont(barHeight: barHeight)
        let chevronSide = max(Metrics.smallIconSize - Metrics.space1, (barHeight * 0.46).rounded())
        chevronFrame = CGRect(x: b.width - pad * 0.75 - chevronSide, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        chevron.frame = chevronFrame
        let control = barHeight - Metrics.space1
        // The more button fades in left of the chevron on hover; its slot is kept.
        moreButton.frame = NSRect(x: max(pad, chevronFrame.minX - Metrics.space1 - control), y: (b.height - control) / 2, width: control, height: control)
        moreButton.isHidden = false
        moreButton.alphaValue = showsMore ? 1 : 0
        // Shown to VoiceOver only when it shows; the header's custom action edits the group always.
        moreButton.setAccessibilityElement(showsMore)
        var trailing = moreButton.frame.minX - Metrics.space2
        if badge.state.isUnread {
            badge.isHidden = false
            let w = badge.preferredWidth, h = SidebarStyle.badgeHeight
            badge.frame = NSRect(x: trailing - w, y: (b.height - h) / 2, width: w, height: h)
            trailing = badge.frame.minX - Metrics.space2
        } else {
            badge.isHidden = true
        }
        if activity.showsGlyph {
            let ind = SidebarStyle.indicatorSize
            activity.frame = NSRect(x: trailing - ind, y: (b.height - ind) / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        }
        let glyphSide = min(SidebarStyle.iconBox, barHeight)
        glyph.isHidden = !hasIcon
        glyph.frame = NSRect(x: pad - Metrics.space1, y: (b.height - glyphSide) / 2, width: glyphSide, height: glyphSide)
        let nx = pad + (hasIcon ? glyphSide : 0)
        let pinSide = Metrics.smallIconSize
        let pinRoom = pinned ? pinSide + Metrics.space2 : 0
        let nameWidth = min(titleIntrinsicWidth, max(0, trailing - pinRoom - nx))
        let nh = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: nx, y: (b.height - nh) / 2, width: nameWidth, height: nh)
        pin.isHidden = !pinned
        pin.frame = NSRect(x: name.frame.maxX + Metrics.space2, y: (b.height - pinSide) / 2, width: pinSide, height: pinSide)
        pill.isHidden = renaming
        pill.frame = NSRect(x: 0, y: (b.height - barHeight) / 2, width: b.width, height: barHeight)
        pill.cornerRadius = (barHeight * 0.23).rounded()
        connector.isHidden = true
        needsDisplay = true
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }

    /// A new group's chip arrives once: it fades and scales up from the
    /// chip's leading edge (Reduce Motion: no scale, the row's fade only).
    func playAppear() {
        guard Motion.animatesMovement else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.86
        scale.toValue = 1
        scale.duration = Motion.duration(MotionSpring.appear)
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pill.add(scale, forKey: "cmux.groupAppear")
    }
}
