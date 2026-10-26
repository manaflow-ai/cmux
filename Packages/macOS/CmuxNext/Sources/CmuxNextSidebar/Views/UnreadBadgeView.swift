import AppKit
import CmuxNextDesign
import Observation
import QuartzCore

/// Unread badge: a count in a quiet small-radius rectangle as tall as the
/// status glyph (tabular digits, no hairline), or a round dot, drawn
/// in the Debug Settings look (`NotificationBadgeLook`, cx-epgo). Every look
/// keeps the same frame, so a switch repaints without moving the row.
final class UnreadBadgeView: NSView {
    private(set) var state: UnreadState = .none
    /// The look painted last.
    private(set) var look = NotificationBadgeLook.classic
    /// A fixed look instead of the Debug Settings one: tab rows draw the quiet
    /// (muted) dot under their workspace's badge (Lawrence 2026-10-14).
    var fixedLook: NotificationBadgeLook? { didSet { if fixedLook != oldValue { needsDisplay = true } } }
    /// A dot in the unread blue of a workspace row (`Palette.statusUnread`) in every look: an
    /// item whose unread is a dot, not a count (Home, Lawrence 2026-10-23).
    var notificationDot = false { didSet { if notificationDot != oldValue { needsDisplay = true } } }
    private let label = ChromeLabel(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay // updateLayer sets colors only
        layer?.cornerCurve = .continuous
        label.font = SidebarStyle.badgeFont
        label.alignment = .center
        addSubview(label)
        isHidden = true // `.none` until configured
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var wantsUpdateLayer: Bool { true }

    /// A row configures its badge on every content change: the same state (and font) asks for no paint or layout.
    func configure(_ state: UnreadState) {
        guard state != self.state || label.font != SidebarStyle.badgeFont else { return }
        self.state = state
        label.setFont(SidebarStyle.badgeFont)
        isHidden = !state.isUnread
        if case let .count(n) = state {
            label.setString(n > 99 ? "99+" : "\(n)")
            label.isHidden = false
        } else {
            label.isHidden = true
        }
        // invalidate: a new state or font (the guard above) paints another look at another width and radius.
        needsDisplay = true; needsLayout = true
    }

    /// Width of a count badge for `count` (without a view).
    static func width(count: Int) -> CGFloat {
        let text = count > 99 ? "99+" : String(count)
        let size = (text as NSString).size(withAttributes: [.font: SidebarStyle.badgeFont])
        return max(SidebarStyle.badgeHeight + Metrics.space2, ceil(size.width) + Metrics.space4)
    }

    /// Width this badge wants at the given height.
    var preferredWidth: CGFloat {
        switch state {
        case .none: 0
        case .dot: SidebarStyle.dotSize
        case .count: max(SidebarStyle.badgeHeight + Metrics.space2, ceil(label.attributedStringValue.size().width) + Metrics.space4)
        }
    }

    override func updateLayer() {
        guard let layer else { return }
        look = fixedLook ?? NotificationBadgeLook.tunable.value
        performWithTheme {
            var colors = self.paint(look, dot: state == .dot)
            if notificationDot, state == .dot { colors = Paint(fill: Palette.statusUnread, text: Palette.statusUnread) }
            label.setColor(colors.text)
            layer.backgroundColor = colors.fill?.cgColor
            layer.borderColor = colors.border?.cgColor
            layer.borderWidth = colors.border == nil ? 0 : colors.borderWidth
        }
    }

    /// One look's colors, from this view's Ghostty theme scope.
    struct Paint {
        var fill: NSColor?
        var text: NSColor
        var border: NSColor?
        var borderWidth: CGFloat = 1
    }

    func paint(_ look: NotificationBadgeLook, dot: Bool) -> Paint {
        performWithTheme { switch (look, dot) {
        case (.classic, true): Paint(fill: Palette.textPrimary.withAlphaComponent(0.85), text: Palette.textPrimary)
        case (.classic, false): Paint(fill: Palette.badgeFill, text: Palette.textPrimary)
        case (.quiet, true): Paint(fill: Palette.textSecondary.withAlphaComponent(0.7), text: Palette.textSecondary)
        case (.quiet, false): Paint(fill: nil, text: Palette.textSecondary)
        case (.outline, true): Paint(fill: nil, text: Palette.textSecondary, border: Palette.textSecondary, borderWidth: 1.5)
        case (.outline, false): Paint(fill: nil, text: Palette.textSecondary, border: Palette.textTertiary)
        case (.tone, true): Paint(fill: Palette.attention, text: Palette.attention)
        case (.tone, false): Paint(fill: Palette.attention.withAlphaComponent(0.18), text: Palette.attention)
        } }
    }

    override func layout() {
        super.layout()
        // Optically centered: the digits' cap height sits in the middle of
        // the rect (the label's line box puts them high), on the pixel grid.
        let h = label.intrinsicContentSize.height, font = label.font ?? SidebarStyle.badgeFont
        let scale = window?.backingScaleFactor ?? 2
        let y = (((bounds.height - font.capHeight) / 2 + font.descender) * scale).rounded() / scale
        label.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
        layer?.cornerRadius = state == .dot ? bounds.height / 2 : Metrics.chipCornerRadius(height: bounds.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { needsLayout = true }
    }
}

/// The sidebar's look watch repaints the badge when Debug Settings changes its look (no polling).
extension UnreadBadgeView: SidebarLookFollower {
    func sidebarLookChanged() {
        // invalidate: the look watch calls this on a changed look only; a fixed look did not change.
        if fixedLook == nil { needsDisplay = true }
    }
}
