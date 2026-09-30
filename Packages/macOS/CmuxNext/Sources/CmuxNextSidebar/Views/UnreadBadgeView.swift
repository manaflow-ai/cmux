import AppKit
import CmuxNextDesign
import QuartzCore

/// Unread badge: a count pill or a dot.
final class UnreadBadgeView: NSView {
    private(set) var state: UnreadState = .none
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.font = SidebarStyle.badgeFont
        label.alignment = .center
        label.textColor = Palette.textPrimary
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
        switch state {
        case .dot:
            layer.backgroundColor = resolvedCGColor(Palette.textPrimary.withAlphaComponent(0.85))
        default:
            layer.backgroundColor = resolvedCGColor(Palette.badgeFill)
        }
        layer.cornerRadius = bounds.height / 2
    }

    override func layout() {
        super.layout()
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        needsDisplay = true
    }
}
