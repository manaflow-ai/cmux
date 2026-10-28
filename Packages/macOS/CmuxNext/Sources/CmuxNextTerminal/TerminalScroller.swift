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
@MainActor
final class TerminalScroller: NSScrollView {
    private let document = TerminalScrollerDocument()
    private var applying = false
    private var shown: TerminalScrollbar?
    /// The user dragged the legacy scroller: show this row at the top.
    var onScrollToRow: ((UInt64) -> Void)?
    /// A wheel event over the legacy scroller belongs to the terminal.
    var onWheel: ((NSEvent) -> Void)?
    /// The style changed; the host lays out again (``reservedWidth``).
    var onStyleChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentView.drawsBackground = false
        contentView.postsBoundsChangedNotifications = true
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
        // queue: .main runs inline for the clip view's post on main (a drag scrolls in order).
        clipObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipMoved() } // main-proof: observer on queue: .main
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var clipObserver: (any NSObjectProtocol)?

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        }
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

    /// Shows `bar` (nil: nothing to scroll).
    func update(_ bar: TerminalScrollbar?) {
        let previous = shown
        shown = bar
        layoutDocument()
        if scrollerStyle == .overlay, TerminalScrollerGeometry.isUserMove(from: previous, to: bar) {
            (verticalScroller as? ThinScroller)?.flash()
        }
    }

    override func layout() {
        super.layout()
        layoutDocument()
    }

    private func layoutDocument() {
        let viewport = contentView.bounds.height
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

    private func clipMoved() {
        guard !applying, let shown else { return }
        let geometry = TerminalScrollerGeometry(bar: shown, viewportHeight: contentView.bounds.height)
        let row = geometry.row(forOriginY: contentView.bounds.origin.y)
        guard row != shown.offsetRows else { return }
        onScrollToRow?(row)
    }

    /// Only the scroller itself: the shown knob (``ThinScroller`` takes clicks on its knob alone),
    /// never the empty document, so everything else stays the terminal's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let scroller = verticalScroller, !scroller.isHidden else { return nil }
        let hit = super.hitTest(point)
        return hit === scroller ? hit : nil
    }

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
