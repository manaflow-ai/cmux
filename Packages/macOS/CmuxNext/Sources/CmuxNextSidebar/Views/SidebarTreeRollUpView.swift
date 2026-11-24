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
    // Match the row's agent-working status treatment, including Reduce Motion and occlusion.
    // Only the running chip uses this mark; the other states keep their quiet dots.
    private let runningIndicator = StatusIndicatorView(frame: .zero)
    private(set) var rollUp: SidebarTreeRollUp?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for chip in chips {
            layer?.addSublayer(chip.fill)
            layer?.addSublayer(chip.dot)
            addSubview(chip.count)
        }
        runningIndicator.ignoresScaleSetting = true
        runningIndicator.tracksWindowOcclusion = true
        runningIndicator.setAccessibilityElement(false) // the parent row already announces the counts
        addSubview(runningIndicator)
        setAccessibilityElement(false) // the row's label says it (`Strings.rollUp`)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ rollUp: SidebarTreeRollUp?) {
        self.rollUp = rollUp
        isHidden = rollUp == nil
        guard let rollUp else {
            refreshRunningIndicator()
            return
        }
        for chip in chips {
            let n = Self.count(chip.state, in: rollUp)
            chip.count.setString(n > 0 ? String(n) : "")
            chip.count.isHidden = n == 0
            chip.dot.isHidden = n == 0 || chip.state == .idle || chip.state == .running
            chip.fill.isHidden = n == 0
        }
        refreshRunningIndicator()
        tint()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // A pooled/hidden parent must not keep a working animation alive while its row is invisible.
    // The shared indicator handles window occlusion and Reduce Motion; the parent supplies visibility.
    private func refreshRunningIndicator() {
        let visibleWork = (rollUp?.running ?? 0) > 0 && !isHiddenOrHasHiddenAncestor
        runningIndicator.configure(visibleWork ? .working : .idle)
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshRunningIndicator()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshRunningIndicator()
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
        case .blocked: Palette.statusAttention
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
    /// The room around a chip's content, each side: 4 pt, so a digit never sits against the fill's edge (it was 2).
    private static var pad: CGFloat { Metrics.space2 }
    /// The gap between chips: the chip's own padding apart, so two chips read as two (it was 2 pt).
    private static var chipGap: CGFloat { Metrics.space2 }
    /// The chip's height, from its font; a chip's mark never takes all of it.
    private static var chipHeight: CGFloat { ceil(SidebarStyle.badgeFont.pointSize + Metrics.space2) }

    /// The mark's box: a quiet dot for waiting, failed and unread, but the running chip's working spinner draws at the
    /// status glyph size every other row's spinner takes (a 5 pt spinner drew as a stray comma beside the count),
    /// inside the chip with a point of air above and below.
    private func markSide(_ chip: Chip) -> CGFloat {
        chip.state == .running ? min(SidebarStyle.statusSpinnerSide, Self.chipHeight - Metrics.space1) : Self.dotSide
    }

    private func width(_ chip: Chip) -> CGFloat {
        chip.count.isHidden ? 0 : ceil(Self.pad + dotWidth(chip) + chip.count.intrinsicContentSize.width + Self.pad)
    }

    /// The dot and its gap; none on the count chip.
    private func dotWidth(_ chip: Chip) -> CGFloat { chip.state == .idle ? 0 : markSide(chip) + Metrics.space1 }

    override var intrinsicContentSize: NSSize {
        let shown = chips.filter { !$0.count.isHidden }
        let widths = shown.map(width).reduce(0, +) + CGFloat(max(0, shown.count - 1)) * Self.chipGap
        return NSSize(width: widths, height: Self.chipHeight)
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
            let side = markSide(chip)
            chip.dot.frame = CGRect(x: x + Self.pad, y: ((h - side) / 2).rounded(), width: side, height: side)
            chip.dot.cornerRadius = side / 2
            if chip.state == .running { runningIndicator.frame = chip.dot.frame }
            // The text box sits `space1` after the dot; the frame adds the label's padding around
            // it (a frame the size of the text alone clipped the digits).
            let text = chip.count.intrinsicContentSize
            chip.count.frame = chip.count.frame(forAlignmentRect: NSRect(x: x + Self.pad + dotWidth(chip), y: (h - text.height) / 2,
                                                                         width: ceil(text.width), height: ceil(text.height)))
            x += w + Self.chipGap
        }
    }
}
