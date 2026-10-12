import AppKit
import CmuxNextDesign
import Observation
import QuartzCore

/// Unread badge: a count in a small rounded rectangle, or a round dot, drawn
/// in the Debug Settings look (`NotificationBadgeLook`, cx-epgo). Every look
/// keeps the same frame, so a switch repaints without moving the row.
final class UnreadBadgeView: NSView {
    private(set) var state: UnreadState = .none
    /// The look painted last.
    private(set) var look = NotificationBadgeLook.classic
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.font = SidebarStyle.badgeFont
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func configure(_ state: UnreadState) {
        self.state = state
        label.font = SidebarStyle.badgeFont
        isHidden = !state.isUnread
        if case let .count(n) = state {
            label.stringValue = n > 99 ? "99+" : "\(n)"
            label.isHidden = false
        } else {
            label.isHidden = true
        }
        needsDisplay = true
        needsLayout = true
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

    /// Reads the look and repaints once when Debug Settings changes it (no polling).
    private func observedLook() -> NotificationBadgeLook {
        guard !observesLook else { return NotificationBadgeLook.tunable.value }
        observesLook = true
        return withObservationTracking {
            NotificationBadgeLook.tunable.value
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observesLook = false
                self?.needsDisplay = true
            }
        }
    }

    /// One observation of the look is registered at a time.
    private var observesLook = false

    override func updateLayer() {
        guard let layer else { return }
        look = observedLook()
        performWithTheme {
            let colors = self.paint(look, dot: state == .dot)
            label.textColor = colors.text
            layer.backgroundColor = colors.fill?.cgColor
            layer.borderColor = colors.border?.cgColor
            layer.borderWidth = colors.border == nil ? 0 : colors.borderWidth
        }
        layer.cornerRadius = state == .dot ? bounds.height / 2 : Metrics.chipCornerRadius(height: bounds.height)
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
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        needsDisplay = true
    }
}
