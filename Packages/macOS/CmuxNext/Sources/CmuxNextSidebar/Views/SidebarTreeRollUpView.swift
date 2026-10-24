import AppKit
import CmuxNextDesign

/// A folded tree parent's roll-up (`sidebar.sessionTree`, lineage nesting): a plain chip with how many
/// sessions it hides, then one small chip per state they are in, a dot and a count each, in a fixed
/// order (waiting on you, failed, running, finished unread). Only states with a count draw. Hidden
/// without a roll-up.
final class SidebarTreeRollUpView: NSView {
    private struct Chip {
        let state: SidebarAgentState
        let dot = CALayer()
        let fill = CALayer()
        let count = SidebarRowView.label(font: SidebarStyle.badgeFont)
    }

    /// The count chip's state is `.idle`: it draws no dot and counts every hidden session.
    private let chips = [SidebarAgentState.idle, .blocked, .failed, .running, .finishedUnread].map { Chip(state: $0) }
    private(set) var rollUp: SidebarTreeRollUp?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for chip in chips {
            layer?.addSublayer(chip.fill)
            layer?.addSublayer(chip.dot)
            addSubview(chip.count)
        }
        setAccessibilityElement(false) // the row's label says it (`Strings.rollUp`)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ rollUp: SidebarTreeRollUp?) {
        self.rollUp = rollUp
        isHidden = rollUp == nil
        guard let rollUp else { return }
        for chip in chips {
            let n = Self.count(chip.state, in: rollUp)
            chip.count.setString(n > 0 ? String(n) : "")
            chip.count.isHidden = n == 0
            chip.dot.isHidden = n == 0 || chip.state == .idle
            chip.fill.isHidden = n == 0
        }
        tint()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    static func count(_ state: SidebarAgentState, in rollUp: SidebarTreeRollUp) -> Int {
        switch state {
        case .blocked: rollUp.blocked
        case .failed: rollUp.failed
        case .running: rollUp.running
        case .finishedUnread: rollUp.unread
        case .idle: rollUp.total
        }
    }

    /// Waiting on you in the theme's attention color, failed in its danger color, running quiet,
    /// finished unread in its highlight (the unseen blue).
    static func color(_ state: SidebarAgentState) -> NSColor {
        switch state {
        case .blocked: Palette.attention
        case .failed: Palette.danger
        case .running, .idle: Palette.textSecondary
        case .finishedUnread: Palette.highlight
        }
    }

    func tint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for chip in chips {
            chip.dot.backgroundColor = Self.color(chip.state).cgColor
            chip.fill.backgroundColor = Palette.badgeFill.cgColor
            chip.count.setColor(chip.state == .running || chip.state == .idle ? Palette.textSecondary : Palette.textPrimary)
        }
        CATransaction.commit()
    }

    private static var dotSide: CGFloat { max(4, SidebarStyle.dotSize - 1) }
    private static var pad: CGFloat { Metrics.space1 }

    private func width(_ chip: Chip) -> CGFloat {
        chip.count.isHidden ? 0 : ceil(Self.pad + dotWidth(chip) + chip.count.intrinsicContentSize.width + Self.pad)
    }

    /// The dot and its gap; none on the count chip.
    private func dotWidth(_ chip: Chip) -> CGFloat { chip.state == .idle ? 0 : Self.dotSide + Metrics.space1 }

    override var intrinsicContentSize: NSSize {
        let shown = chips.filter { !$0.count.isHidden }
        let widths = shown.map(width).reduce(0, +) + CGFloat(max(0, shown.count - 1)) * Metrics.space1
        return NSSize(width: widths, height: ceil(SidebarStyle.badgeFont.pointSize + Metrics.space2))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var x: CGFloat = 0
        let h = bounds.height
        for chip in chips where !chip.count.isHidden {
            let w = width(chip)
            chip.fill.frame = CGRect(x: x, y: 0, width: w, height: h)
            chip.fill.cornerRadius = Metrics.chipCornerRadius(height: h)
            let side = Self.dotSide
            chip.dot.frame = CGRect(x: x + Self.pad, y: (h - side) / 2, width: side, height: side)
            chip.dot.cornerRadius = side / 2
            let text = chip.count.intrinsicContentSize
            chip.count.frame = NSRect(x: x + Self.pad + dotWidth(chip), y: (h - text.height) / 2,
                                      width: ceil(text.width), height: ceil(text.height))
            x += w + Metrics.space1
        }
    }
}
