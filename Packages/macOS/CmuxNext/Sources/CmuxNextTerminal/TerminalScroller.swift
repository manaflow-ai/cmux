import AppKit
import CmuxNextDesign

/// The terminal's scroller (SCROLLBARS-THIN), from Ghostty's scrollbar action
/// (`TerminalScrollbar`: total, offset and visible rows). It is the shared ``ThinScroller``, an
/// overlay one whatever the macOS "Show scroll bars" setting (``SystemScrollers/nativeStyle``):
/// hidden at rest, shown while the viewport moves through the scrollback (wheel, keyboard, search),
/// never for output that only follows the bottom, and fading out after (Lawrence 2026-10-23, msg
/// 11494). While it is shown the pointer near it widens it and it can be dragged; at rest it takes
/// no clicks and the pointer does not reveal it, so the last column stays the terminal's. The style
/// is pinned: AppKit resets a scroll view to the system's style when the setting changes, which
/// here would briefly reserve a legacy strip and take clicks.
///
/// It is an NSScrollView over an empty document whose height stands for the scrollback, so the
/// knob tracks the scrollback as any scroll view's does.
///
/// The knob is placed at most once per display frame for output, as Chrome places
/// scrollbars from the scroll tree once per frame (`LayerTreeImpl::UpdateScrollbarGeometries`,
/// cc/trees/layer_tree_impl.cc): the host feeds ``update(_:)`` from one `.visible` FrameObservation,
/// the frame-phase owner that applies the latest scrollbar once per frame, and a person's scroll in
/// that input's own response pass. The scroller places each bar it gets at once and keeps no frame
/// client, so it never lags the content it describes and wakes no frame of its own. A layout places
/// the knob only for a new clip size.
@MainActor
final class TerminalScroller: NSScrollView, ScrollGeometryClient {
    private let document = TerminalScrollerDocument()
    private var applying = false
    /// The scrollbar the knob shows (Ghostty's last one).
    private(set) var shown: TerminalScrollbar?
    /// The row the last knob-drag report asked Ghostty for, until Ghostty's next scrollbar comes: the
    /// row the terminal will be at, which a later drag move is compared with.
    private var requestedRow: UInt64?
    /// The clip size the document was last laid out for.
    private var placedViewport: CGSize = .zero
    /// Knob placements made (tests: one per scrollbar the host delivers).
    private(set) var knobPlacements = 0
    /// The user dragged the legacy scroller: show this row at the top.
    var onScrollToRow: ((UInt64) -> Void)?
    /// A wheel event over the legacy scroller belongs to the terminal.
    var onWheel: ((NSEvent) -> Void)?
    /// The style changed; the host lays out again (``reservedWidth``).
    var onStyleChange: (() -> Void)?

    /// Stays on the main thread: every wheel event is the terminal's (`onWheel`), which
    /// moves Ghostty's viewport per event; a responsive gesture would scroll the empty document instead.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        // A scroller drag moves the clip; it pushes each move here, in order (`scrollGeometryDidChange`).
        ScrollGeometryClipView.install(in: self).addClient(self)
        contentView.drawsBackground = false
        documentView = document
        let thin = ThinScroller()
        thin.showsOnScroll = false // only a move through the scrollback shows it (`update`)
        thin.revealsNearPointerAtRest = false // the last column is the terminal's
        verticalScroller = thin
        apply(SystemScrollers.nativeStyle)
        // AppKit resets a scroll view's style when the setting changes.
        SystemScrollers.observe(self) { [weak self] _ in
            self?.apply(SystemScrollers.nativeStyle)
            self?.onStyleChange?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Pinned to ``SystemScrollers/nativeStyle``, AppKit's own reset on a setting change included.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = SystemScrollers.nativeStyle }
    }

    private func apply(_ style: NSScroller.Style) {
        scrollerStyle = style
        // Both styles hide the scroller while everything fits (the document equals the viewport).
        autohidesScrollers = true
    }

    /// The width the host keeps free for the scroller: the legacy scroller's, else none.
    var reservedWidth: CGFloat {
        scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    /// The frame for a host of `bounds`: a strip at the trailing edge.
    func strip(in bounds: CGRect) -> CGRect {
        let width = max(reservedWidth, ThinScroller.width)
        return CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
    }

    /// Shows `bar` (nil: nothing to scroll) at once, flashing the overlay knob for a move through the
    /// scrollback. It answers the last knob-drag report.
    func update(_ bar: TerminalScrollbar?) {
        requestedRow = nil
        let previous = shown
        shown = bar
        placeKnob()
        if scrollerStyle == .overlay, TerminalScrollerGeometry.isUserMove(from: previous, to: bar) {
            (verticalScroller as? ThinScroller)?.flash()
        }
    }

    /// The scroll view sizes its clip here. A taller clip at the bottom of the scrollback (the window
    /// or the pane grows) gets its origin clamped into the document by AppKit: that move is this
    /// layout's, not a person's scroll, so it asks Ghostty for no row (``scrollGeometryDidChange(_:)``),
    /// and ``layout()`` places the knob for the new clip size.
    override func tile() {
        let wasApplying = applying
        applying = true
        defer { applying = wasApplying }
        super.tile()
    }

    override func layout() {
        super.layout()
        // Only a new clip size moves the knob; the scroller's own document change lays out again.
        guard contentView.bounds.size != placedViewport else { return }
        placeKnob()
    }

    private func placeKnob() {
        knobPlacements += 1
        layoutDocument()
    }

    private func layoutDocument() {
        placedViewport = contentView.bounds.size
        let viewport = placedViewport.height
        guard viewport > 0 else { return }
        let geometry = TerminalScrollerGeometry(bar: shown, viewportHeight: viewport)
        applying = true
        defer { applying = false }
        let frame = CGRect(x: 0, y: 0, width: contentView.bounds.width, height: geometry.documentHeight)
        if document.frame != frame { document.frame = frame }
        if contentView.bounds.origin.y != geometry.originY {
            contentView.scroll(to: CGPoint(x: 0, y: geometry.originY))
            reflectScrolledClipView(contentView)
        }
    }

    /// A knob drag: every clip move reports its row at once, in order, unless the terminal is already
    /// going to be at it (the row last asked for while Ghostty has not answered, else Ghostty's own).
    /// A move that comes with a new clip size is never a drag: AppKit clamped the origin of a resized
    /// clip into the document, and the row it gives is the old scrollbar read at the new size.
    func scrollGeometryDidChange(_ change: ScrollGeometryChange) {
        guard change.contains(.scrolled), !change.contains(.resized), !applying, let shown else { return }
        let geometry = TerminalScrollerGeometry(bar: shown, viewportHeight: contentView.bounds.height)
        let row = geometry.row(forOriginY: contentView.bounds.origin.y)
        guard row != (requestedRow ?? shown.offsetRows) else { return }
        requestedRow = row
        onScrollToRow?(row)
    }

    /// Only the scroller itself: the shown knob (``ThinScroller`` takes clicks on its knob alone),
    /// never the empty document, so everything else stays the terminal's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let scroller = verticalScroller, !scroller.isHidden else { return nil }
        let hit = super.hitTest(point)
        return hit === scroller ? hit : nil
    }

    // local-monitor-allow: forwards the wheel to the terminal under the scroller (TerminalHostView.onWheel), which coalesces it per frame; order and count kept
    override func scrollWheel(with event: NSEvent) {
        onWheel?(event)
    }
}

/// The scroller's empty document (top-left origin, like the terminal's rows).
private final class TerminalScrollerDocument: NSView {
    nonisolated override var isFlipped: Bool { true }
}

/// How Ghostty's scrollbar maps onto the scroller's document (pure, tested).
struct TerminalScrollerGeometry: Equatable {
    var documentHeight: CGFloat
    var originY: CGFloat
    private var total: UInt64
    private var visible: UInt64

    /// The document is the viewport scaled by total / visible rows; its origin is the offset's share.
    init(bar: TerminalScrollbar?, viewportHeight: CGFloat) {
        guard let bar, bar.visibleRows > 0, bar.totalRows > bar.visibleRows else {
            documentHeight = viewportHeight
            originY = 0
            total = bar?.totalRows ?? 0
            visible = bar?.visibleRows ?? 0
            return
        }
        total = bar.totalRows
        visible = bar.visibleRows
        let rowHeight = viewportHeight / CGFloat(bar.visibleRows)
        documentHeight = rowHeight * CGFloat(bar.totalRows)
        let maxOffset = bar.totalRows - bar.visibleRows
        originY = rowHeight * CGFloat(min(bar.offsetRows, maxOffset))
    }

    /// The top row for a clip origin (a scroller drag), clamped to the scrollback.
    func row(forOriginY y: CGFloat) -> UInt64 {
        guard total > visible, documentHeight > 0 else { return 0 }
        let rowHeight = documentHeight / CGFloat(total)
        let row = (max(0, y) / rowHeight).rounded()
        return min(UInt64(row), total - visible)
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
