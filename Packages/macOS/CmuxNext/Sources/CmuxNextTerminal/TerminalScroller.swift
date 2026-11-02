import AppKit
import CmuxNextDesign

/// The terminal's scroller (SCROLLBARS-THIN), from Ghostty's scrollbar action
/// (`TerminalScrollbar`: total, offset and visible rows). It is the shared ``ThinScroller``, an
/// overlay one whatever the macOS "Show scroll bars" setting (``SystemScrollers/nativeStyle``):
/// hidden at rest, shown while the viewport moves through the scrollback (wheel, keyboard, search),
/// never for output that only follows the bottom, and fading out after (Lawrence 2026-10-23, msg
/// 11494). While it is shown the pointer near it widens it and it can be dragged; at rest it takes
/// no clicks and the pointer does not reveal it, so the last column stays the terminal's. The style
/// is pinned to ``SystemScrollers/nativeStyle``, also after the setting changes, so it never
/// reserves a legacy strip.
///
/// It is a plain view that holds the knob, not a scroll view: a scroll view tiles its clip view and
/// lays out its scroll-edge pockets on every frame change, which in a split's first frame was the new
/// pane's largest layout item (RESIZE VIDEOS F1). The knob's length and place come from the bar
/// (``TerminalScrollerGeometry``); a knob drag scrolls the terminal to the row it points at.
@MainActor
final class TerminalScroller: NSView {
    let thin = ThinScroller()
    private var shown: TerminalScrollbar?
    /// The user dragged the knob: show this row at the top.
    var onScrollToRow: ((UInt64) -> Void)?
    /// A wheel event over the knob belongs to the terminal.
    var onWheel: ((NSEvent) -> Void)?
    /// The style changed; the host lays out again (``reservedWidth``).
    var onStyleChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        thin.showsOnScroll = false // only a move through the scrollback shows it (`update`)
        thin.revealsNearPointerAtRest = false // the last column is the terminal's
        thin.scrollerStyle = SystemScrollers.nativeStyle
        thin.autoresizingMask = [.width, .height]
        thin.target = self
        thin.action = #selector(knobMoved)
        addSubview(thin)
        update(nil)
        SystemScrollers.observe(self) { [weak self] _ in
            self?.thin.scrollerStyle = SystemScrollers.nativeStyle
            self?.onStyleChange?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The width the host keeps free for the scroller: the legacy scroller's, else none.
    var reservedWidth: CGFloat { Self.reservedWidth(for: thin.scrollerStyle) }

    /// The strip a scroller of `style` takes beside the surface: a legacy one's width, none for an overlay one.
    static func reservedWidth(for style: NSScroller.Style) -> CGFloat {
        style == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    /// The frame for a host of `bounds`: a strip at the trailing edge.
    func strip(in bounds: CGRect) -> CGRect {
        let width = max(reservedWidth, ThinScroller.width)
        return CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
    }

    /// Shows `bar` (nil: nothing to scroll).
    func update(_ bar: TerminalScrollbar?) {
        let previous = shown
        shown = bar
        let geometry = TerminalScrollerGeometry(bar: bar)
        thin.isHidden = !geometry.scrolls
        thin.isEnabled = geometry.scrolls
        if thin.knobProportion != geometry.knobProportion { thin.knobProportion = geometry.knobProportion }
        if thin.doubleValue != geometry.value { thin.doubleValue = geometry.value }
        if thin.scrollerStyle == .overlay, TerminalScrollerGeometry.isUserMove(from: previous, to: bar) {
            thin.flash()
        }
    }

    @objc private func knobMoved() {
        guard let shown else { return }
        let row = TerminalScrollerGeometry(bar: shown).row(forValue: thin.doubleValue)
        guard row != shown.offsetRows else { return }
        onScrollToRow?(row)
    }

    /// Only the shown knob (``ThinScroller`` takes clicks on its knob alone), so everything else
    /// stays the terminal's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !thin.isHidden else { return nil }
        let hit = super.hitTest(point)
        return hit === thin ? hit : nil
    }

    override func scrollWheel(with event: NSEvent) {
        onWheel?(event)
    }
}

/// How Ghostty's scrollbar maps onto the knob (pure, tested): its length is the visible rows'
/// share of all rows, its place the offset's share of the rows above the last screen.
struct TerminalScrollerGeometry: Equatable {
    var knobProportion: CGFloat
    var value: Double
    private var total: UInt64
    private var visible: UInt64

    /// There is a scrollback to move through.
    var scrolls: Bool { visible > 0 && total > visible }

    init(bar: TerminalScrollbar?) {
        total = bar?.totalRows ?? 0
        visible = bar?.visibleRows ?? 0
        guard let bar, bar.visibleRows > 0, bar.totalRows > bar.visibleRows else {
            knobProportion = 1
            value = 0
            return
        }
        let maxOffset = bar.totalRows - bar.visibleRows
        knobProportion = CGFloat(bar.visibleRows) / CGFloat(bar.totalRows)
        value = Double(min(bar.offsetRows, maxOffset)) / Double(maxOffset)
    }

    /// The top row for a knob value (a knob drag), clamped to the scrollback.
    func row(forValue value: Double) -> UInt64 {
        guard scrolls else { return 0 }
        let maxOffset = total - visible
        let row = (min(1, max(0, value)) * Double(maxOffset)).rounded()
        return min(UInt64(row), maxOffset)
    }

    /// Whether the viewport moved through the scrollback (a reason to show an overlay scroller):
    /// output that keeps the viewport pinned to the bottom is not a move.
    static func isUserMove(from old: TerminalScrollbar?, to new: TerminalScrollbar?) -> Bool {
        guard let old, let new, new.totalRows > new.visibleRows else { return false }
        guard old.offsetRows != new.offsetRows else { return false }
        func atBottom(_ bar: TerminalScrollbar) -> Bool { bar.offsetRows + bar.visibleRows >= bar.totalRows }
        return !(atBottom(old) && atBottom(new))
    }
}
