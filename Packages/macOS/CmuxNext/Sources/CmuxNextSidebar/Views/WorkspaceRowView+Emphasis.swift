import AppKit
import CmuxNextDesign

/// A row's part of the notification surfaces (`SidebarNotificationEmphasis`). Only the loud-rows look
/// changes the row itself: a workspace with a notification paints solid in its badge's color (blue
/// unread, orange needs you, red failed) with white text, and a white pill with the count, or "!",
/// stands in for the dot. The inbox shelf and the arrival card leave rows as they are (SidebarView+Attention).
@MainActor
final class WorkspaceRowEmphasis {
    private(set) var style = SidebarNotificationEmphasis.standard
    private(set) var attention: WorkspaceRowAttention?
    let pill = NotificationPillView()

    /// The row paints loud: the loud-rows look on a row with a notification.
    var isLoud: Bool { style == .loudRows && attention != nil }

    func update(style: SidebarNotificationEmphasis, attention: WorkspaceRowAttention?) {
        (self.style, self.attention) = (style, attention)
    }
}

/// A capsule with the count, in the row's color on white (the loud row's mark in place of the dot).
final class NotificationPillView: NSView {
    private let label = NSTextField(labelWithString: "")
    static var height: CGFloat { SidebarStyle.badgeHeight + 2 }
    static let pad: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
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

    func paint(fill: NSColor, text: NSColor) {
        layer?.backgroundColor = fill.cgColor
        label.textColor = text
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
    /// Sets the row's part after its badges (`configureBadges`); nil `badges` clears it (a placeholder, or the
    /// `trailing` badge style that keeps the count). `leading` is the badge's first glyph: a row whose badge leads
    /// with work in progress is not loud, so its spinner stays.
    func configureEmphasis(_ badges: WorkspaceRowBadges?, leading: StatusIndicatorState? = nil, style: SidebarNotificationEmphasis) {
        let attention = badges.flatMap { WorkspaceRowAttention($0, leading: leading) }
        emphasis.update(style: style, attention: attention)
        let loud = emphasis.isLoud
        if loud || emphasis.pill.superview != nil {
            if emphasis.pill.superview == nil { addSubview(emphasis.pill) }
            emphasis.pill.isHidden = !loud
            if let attention, loud { emphasis.pill.configure(text: attention.pillText) }
            // The badge's summary ("3 unread, Needs you") stays under the pointer on the pill.
            emphasis.pill.themedToolTip = loud ? rowBadge.themedToolTip : nil
        }
        // The pill stands in for the badge's glyphs on a loud row.
        rowBadge.isHidden = rowBadge.states.isEmpty || loud
        if loud {
            title.font = NSFont.systemFont(ofSize: SidebarStyle.titleFont.pointSize, weight: TypeScale.emphasis)
        }
        (needsDisplay, needsLayout) = (true, true)
    }

    /// The pill on the trailing column, where the dot would be; nil when it does not show.
    func layoutEmphasisPill(column: CGFloat, cy: CGFloat) -> NSView? {
        guard emphasis.isLoud else { return nil }
        let pill = emphasis.pill, h = NotificationPillView.height, w = pill.preferredWidth
        let scale = window?.backingScaleFactor ?? 1
        pill.frame = NSRect(x: SidebarStyle.pixelSnapped(column + h / 2 - w, scale: scale),
                            y: SidebarStyle.pixelSnapped(cy - h / 2, scale: scale), width: w, height: h)
        return pill
    }

    /// Inside `updateLayer`'s theme scope, so the row takes the theme's status color as the badge's dot does;
    /// returns the fill the row paints. A loud row paints solid (a step stronger hovered or selected, so selection
    /// still reads) and its text white; every other row keeps `fill`.
    func paintEmphasis(over fill: NSColor?, colorFilled: Bool) -> NSColor? {
        guard emphasis.isLoud, let attention = emphasis.attention else { return fill }
        let color = attention.color
        let strong = isSelected || isDropTarget || isSecondarySelected
        let hovered = isHovered && !isPlaceholderRow && DesignSettings.shared.showsHoverFills
        title.textColor = .white
        subtitle.setColor(NSColor.white.withAlphaComponent(0.85))
        timeLabel.setColor(NSColor.white.withAlphaComponent(0.75))
        emphasis.pill.paint(fill: .white, text: color)
        return color.withAlphaComponent(strong ? 1 : hovered ? 0.92 : 0.82)
    }
}
