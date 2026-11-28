import AppKit
import CmuxNextDesign

/// A row's roll-up on its title line: what under it may need the person. A folded tree parent's hidden
/// sessions (`sidebar.sessionTree`, lineage nesting) and a chat's failed subagents it lists no line for
/// (`WorkspaceRowContent.drawnRollUp`). Only two states draw, each the rows' own status mark (the yellow needs-you
/// mark, the red info mark, as `RowBadgeView` draws them) and a count only past one, in a fixed order: waiting on
/// you, failed. Lawrence 2026-11-25: "the 1 red dot thing is also inconsistent; notice how we have the red i for all
/// the other ones". How many it hides, what runs and what finished unread draw nothing:
/// Leo 2026-11-23, on a row reading "⚠ [1] [•1]": "this is weird and bad and unncessary"; 05:09Z: "state can
/// fucking only be relevant when you may need to investigate/take action." The row's own unread dot stays the
/// one unread mark. Hidden when nothing actionable is under the row; VoiceOver still names every count
/// (`Strings.rollUp`).
final class SidebarTreeRollUpView: NSView {
    private struct Chip {
        let state: SidebarAgentState
        let mark: StatusIndicatorView = {
            let view = StatusIndicatorView()
            view.usesStatusColors = true
            view.ignoresScaleSetting = true
            return view
        }()
        let count = SidebarRowView.label(font: SidebarStyle.badgeFont)
    }

    /// The states a person may need to act on; the others (idle, running, finished unread) draw nothing.
    static let drawnStates: [SidebarAgentState] = [.blocked, .failed]
    private let chips = SidebarTreeRollUpView.drawnStates.map { Chip(state: $0) }
    private(set) var rollUp: SidebarTreeRollUp?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for chip in chips {
            chip.mark.configure(Self.indicator(chip.state))
            addSubview(chip.mark)
            addSubview(chip.count)
        }
        setAccessibilityElement(false) // the row's label says it (`Strings.rollUp`)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ rollUp: SidebarTreeRollUp?) {
        self.rollUp = rollUp
        var any = false
        for chip in chips {
            let n = rollUp.map { Self.count(chip.state, in: $0) } ?? 0
            // One reads as the mark alone, like every row's own mark; more add the count.
            chip.count.setString(n > 1 ? String(n) : "")
            chip.count.isHidden = n <= 1
            chip.mark.isHidden = n == 0
            any = any || n > 0
        }
        isHidden = !any
        guard any else { return }
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

    /// The shared status mark a state draws: waiting on you, failed.
    static func indicator(_ state: SidebarAgentState) -> StatusIndicatorState {
        state == .blocked ? .waiting : .error
    }

    /// Waiting on you in the theme's attention color, failed in its danger color.
    static func color(_ state: SidebarAgentState) -> NSColor {
        switch state {
        case .blocked: Palette.statusAttention
        case .failed: Palette.danger
        case .running, .idle: Palette.textSecondary
        case .finishedUnread: Palette.highlight
        }
    }

    func tint() {
        for chip in chips {
            chip.mark.needsDisplay = true
            chip.count.setColor(Palette.textSecondary)
        }
    }

    /// The mark's side: the rows' own status mark box (`RowBadgeView.markSide`).
    private static var markSide: CGFloat { SidebarStyle.statusMarkSide }

    /// A drawn chip's width: its mark, then a gap and its count past one.
    private func width(_ chip: Chip) -> CGFloat {
        guard !chip.mark.isHidden else { return 0 }
        return chip.count.isHidden ? Self.markSide : ceil(Self.markSide + Metrics.space1 + chip.count.intrinsicContentSize.width)
    }

    override var intrinsicContentSize: NSSize {
        let shown = chips.filter { !$0.mark.isHidden }
        let widths = shown.map(width).reduce(0, +) + CGFloat(max(0, shown.count - 1)) * Metrics.space2
        return NSSize(width: widths, height: max(Self.markSide, ceil(SidebarStyle.badgeFont.pointSize + Metrics.space2)))
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let h = bounds.height
        for chip in chips where !chip.mark.isHidden {
            let side = Self.markSide
            chip.mark.frame = CGRect(x: x, y: ((h - side) / 2).rounded(), width: side, height: side)
            // The text box sits `space1` after the mark; the frame adds the label's padding around
            // it (a frame the size of the text alone clipped the digits).
            let text = chip.count.intrinsicContentSize
            chip.count.frame = chip.count.frame(forAlignmentRect: NSRect(x: x + side + Metrics.space1, y: (h - text.height) / 2,
                                                                         width: ceil(text.width), height: ceil(text.height)))
            x += width(chip) + Metrics.space2
        }
    }
}
