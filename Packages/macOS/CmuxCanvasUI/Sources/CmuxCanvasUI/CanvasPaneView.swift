import AppKit
import SwiftUI
import CmuxCanvas

/// Delegate through which a pane view reports gestures to the canvas root.
@MainActor
protocol CanvasPaneViewDelegate: AnyObject {
    func paneView(_ view: CanvasPaneView, mouseDownAt documentPoint: CGPoint, region: CanvasPaneHitRegion)
    func paneView(_ view: CanvasPaneView, draggedTo documentPoint: CGPoint, modifiers: NSEvent.ModifierFlags)
    func paneViewDidEndDrag(_ view: CanvasPaneView)
    /// Dragging a tab of a multi-tab pane: tear the tab out into its own pane
    /// and continue the drag with that new pane (the canvas twin of split tab
    /// drag). Dropping on another pane's tab bar joins it there.
    func paneView(_ view: CanvasPaneView, requestTearOutTab panelId: UUID, atDocumentPoint point: CGPoint)
    func paneView(_ view: CanvasPaneView, didSelectTab panelId: UUID)
    func paneView(_ view: CanvasPaneView, didCloseTab panelId: UUID)
    func paneViewDidRequestFocus(_ view: CanvasPaneView)
}

/// One pane on the canvas: focus-ring chrome, a title strip that doubles as
/// the move-drag handle, resize bands on every edge and corner, and a content
/// container hosting the panel's view.
@MainActor
final class CanvasPaneView: NSView {
    let paneID: CanvasPaneID
    weak var delegate: (any CanvasPaneViewDelegate)?

    /// The container the panel content view is mounted into.
    let contentContainer = NSView()
    private(set) var isContentSuppressedForDrag = false

    private let titleBarHost: NSHostingView<CanvasPaneTitleBarView>
    private var chrome = CanvasPaneChrome(
        tabs: [],
        selectedTabId: nil,
        isFocused: false,
        closeActionLabel: ""
    )
    private var activeDragRegion: CanvasPaneHitRegion?
    private var dragStartedMoving = false
    private var dragStartDocumentPoint: CGPoint = .zero
    /// Tab/close hit rects in tab-bar coordinates, reported by SwiftUI.
    private var tabHitRegions = CanvasTabHitRegions()
    private var tabOrder: [UUID] = []
    private var hoveredTabId: UUID?
    private var titleBarTrackingArea: NSTrackingArea?
    /// Pending click target resolved at mouse-down, fired at mouse-up when
    /// no drag started.
    private var pendingTabClick: (panelId: UUID, isClose: Bool)?
    /// Horizontal tab-strip scroll offset and the measured content width,
    /// used to scroll overflowing tabs (the pane view owns the title-bar's
    /// scroll events, so a SwiftUI ScrollView can't be used).
    private var tabScrollOffset: CGFloat = 0
    private var tabContentWidth: CGFloat = 0

    /// Pane fill behind the content, resolved by the host through
    /// ``CanvasTheme``.
    var paneBackground: NSColor = .windowBackgroundColor {
        didSet {
            guard paneBackground != oldValue else { return }
            applyChromeColors()
            rebuildTitleBar()
        }
    }

    private static let resizeBandWidth: CGFloat = 6
    private static let cornerBandWidth: CGFloat = 12
    private static let cornerRadius: CGFloat = 9
    private static let dragActivationDistance: CGFloat = 2

    init(paneID: CanvasPaneID) {
        self.paneID = paneID
        self.titleBarHost = NSHostingView(rootView: CanvasPaneTitleBarView(
            chrome: CanvasPaneChrome(tabs: [], selectedTabId: nil, isFocused: false, closeActionLabel: ""),
            barBackground: .windowBackgroundColor,
            hoveredTabId: nil,
            scrollOffset: 0,
            onHitRegionsChanged: { _ in },
            onContentWidthChanged: { _ in }
        ))
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        titleBarHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleBarHost)
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            titleBarHost.topAnchor.constraint(equalTo: topAnchor),
            titleBarHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBarHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBarHost.heightAnchor.constraint(equalToConstant: CanvasPaneTitleBarView.height),
            contentContainer.topAnchor.constraint(equalTo: titleBarHost.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyChromeColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    func setContentSuppressedForDrag(_ suppressed: Bool) {
        guard isContentSuppressedForDrag != suppressed else { return }
        isContentSuppressedForDrag = suppressed
        contentContainer.isHidden = suppressed
    }

    /// Updates the tab strip and focus ring. No-op when nothing changed.
    func updateChrome(_ chrome: CanvasPaneChrome) {
        guard chrome != self.chrome else { return }
        self.chrome = chrome
        tabOrder = chrome.tabs.map(\.id)
        if let currentHoveredTabId = hoveredTabId,
           !tabOrder.contains(currentHoveredTabId) {
            hoveredTabId = nil
        }
        // Fewer tabs may make the current offset invalid; clamp on next render.
        clampTabScrollOffset()
        rebuildTitleBar()
    }

    private func rebuildTitleBar() {
        titleBarHost.rootView = CanvasPaneTitleBarView(
            chrome: chrome,
            barBackground: paneBackground,
            hoveredTabId: hoveredTabId,
            scrollOffset: tabScrollOffset,
            onHitRegionsChanged: { [weak self] regions in
                self?.tabHitRegions = regions
            },
            onContentWidthChanged: { [weak self] width in
                guard let self, self.tabContentWidth != width else { return }
                self.tabContentWidth = width
                self.clampTabScrollOffset()
            }
        )
        applyChromeColors()
    }

    private var tabHitTester: CanvasTabHitTester {
        CanvasTabHitTester(
            tabOrder: tabOrder,
            hitRegions: tabHitRegions
        )
    }

    /// Maximum horizontal scroll so the last tab can't be pulled past the bar.
    private var maxTabScrollOffset: CGFloat {
        max(0, tabContentWidth - bounds.width)
    }

    private func clampTabScrollOffset() {
        let clamped = min(max(0, tabScrollOffset), maxTabScrollOffset)
        if clamped != tabScrollOffset {
            tabScrollOffset = clamped
            rebuildTitleBar()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Only handle scrolls over the title bar with overflowing tabs;
        // everything else (content scroll, no overflow) passes through.
        let local = convert(event.locationInWindow, from: nil)
        guard local.y <= CanvasPaneTitleBarView.height, maxTabScrollOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }
        // Use the dominant axis so a mostly-vertical trackpad swipe still
        // scrolls the horizontal tab strip.
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        guard delta != 0 else { return }
        let next = min(max(0, tabScrollOffset - delta), maxTabScrollOffset)
        guard next != tabScrollOffset else { return }
        tabScrollOffset = next
        rebuildTitleBar()
    }

    private func applyChromeColors() {
        layer?.borderColor = chrome.isFocused
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.cgColor
        layer?.borderWidth = chrome.isFocused ? 2 : 1
        layer?.backgroundColor = paneBackground.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let titleBarTrackingArea {
            removeTrackingArea(titleBarTrackingArea)
        }
        let rect = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: min(bounds.height, CanvasPaneTitleBarView.height)
        )
        guard !rect.isEmpty else {
            titleBarTrackingArea = nil
            return
        }
        let trackingArea = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        titleBarTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoveredTab(from: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredTab(from: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredTab(nil)
    }

    private func updateHoveredTab(from event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard local.y <= CanvasPaneTitleBarView.height else {
            setHoveredTab(nil)
            return
        }
        let barPoint = titleBarHost.convert(event.locationInWindow, from: nil)
        setHoveredTab(tabHitTester.tab(at: barPoint))
    }

    private func setHoveredTab(_ tabId: UUID?) {
        guard hoveredTabId != tabId else { return }
        hoveredTabId = tabId
        rebuildTitleBar()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

    // MARK: Hit regions

    private func hitRegion(at point: CGPoint) -> CanvasPaneHitRegion? {
        var edges: CanvasResizeEdges = []
        if point.x <= Self.resizeBandWidth { edges.insert(.left) }
        if point.x >= bounds.width - Self.resizeBandWidth { edges.insert(.right) }
        if point.y <= Self.resizeBandWidth { edges.insert(.top) }
        if point.y >= bounds.height - Self.resizeBandWidth { edges.insert(.bottom) }

        // Widen corners so diagonal grabs are easy.
        if edges == .left || edges == .right {
            if point.y <= Self.cornerBandWidth { edges.insert(.top) }
            if point.y >= bounds.height - Self.cornerBandWidth { edges.insert(.bottom) }
        } else if edges == .top || edges == .bottom {
            if point.x <= Self.cornerBandWidth { edges.insert(.left) }
            if point.x >= bounds.width - Self.cornerBandWidth { edges.insert(.right) }
        }

        if !edges.isEmpty {
            return .resize(edges)
        }
        if point.y <= CanvasPaneTitleBarView.height {
            return .titleBar
        }
        return nil
    }

    func containsBodyPoint(_ point: CGPoint) -> Bool {
        bounds.contains(point) && hitRegion(at: point) == nil
    }

    /// The pane owns every event over the resize rim AND the tab bar: drags
    /// stay on the fast AppKit path and tab clicks resolve deterministically
    /// against the reported hit regions (SwiftUI gesture recognizers fought
    /// drags and swallowed close clicks).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        guard result != nil, result !== self else { return result }
        let local = convert(point, from: superview)
        if hitRegion(at: local) != nil {
            return self
        }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let region = hitRegion(at: local) else {
            // Body clicks are focused by CanvasRootView's local monitor before
            // terminal content receives the same mouse-down.
            super.mouseDown(with: event)
            return
        }
        pendingTabClick = nil
        if case .titleBar = region {
            let barPoint = titleBarHost.convert(event.locationInWindow, from: nil)
            let hitTester = tabHitTester
            let tabUnderPointer = hitTester.tab(at: barPoint)
            let visibleHoveredTabId = hoveredTabId
            setHoveredTab(tabUnderPointer)
            if let panelId = hitTester.closeTab(at: barPoint, hoveredTabId: visibleHoveredTabId) {
                pendingTabClick = (panelId, true)
            } else if let panelId = tabUnderPointer {
                pendingTabClick = (panelId, false)
            }
        }
        guard let documentView = superview else { return }
        let documentPoint = documentView.convert(event.locationInWindow, from: nil)
        // Whether a drag should manipulate the tab (tear it out) versus move
        // the whole pane is decided once the drag actually starts moving (in
        // mouseDragged), so a plain click still selects the tab. See there.
        activeDragRegion = region
        dragStartedMoving = false
        dragStartDocumentPoint = documentPoint
        delegate?.paneViewDidRequestFocus(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let region = activeDragRegion, let documentView = superview else {
            super.mouseDragged(with: event)
            return
        }
        let documentPoint = documentView.convert(event.locationInWindow, from: nil)
        if !dragStartedMoving {
            let dx = abs(documentPoint.x - dragStartDocumentPoint.x)
            let dy = abs(documentPoint.y - dragStartDocumentPoint.y)
            guard dx >= Self.dragActivationDistance || dy >= Self.dragActivationDistance else { return }
            dragStartedMoving = true
            // A drag that began on a tab (not its close glyph) of a multi-tab
            // pane tears that tab out into its own pane and keeps dragging it,
            // matching split-layout tab drag: dragging a tab manipulates the
            // tab, not the whole pane. Dropping it on another pane's tab bar
            // joins it there (handled in paneViewDidEndDrag). Single-tab panes
            // (the tab *is* the pane) and drags on the empty title-bar area
            // move the whole pane.
            //
            // Holding Command targets the pane instead of the tab (mirrors
            // Command+scroll, which pans the canvas instead of the pane's
            // content): Cmd+drag a tab moves the whole pane. This guarantees a
            // move handle even when the tab bar is full and there is no empty
            // title-bar region to grab.
            if case .titleBar = region,
               let click = pendingTabClick, !click.isClose,
               chrome.tabs.count > 1,
               !event.modifierFlags.contains(.command) {
                pendingTabClick = nil
                delegate?.paneView(self, requestTearOutTab: click.panelId, atDocumentPoint: documentPoint)
                return
            }
            delegate?.paneView(self, mouseDownAt: dragStartDocumentPoint, region: region)
        }
        autoscroll(with: event)
        delegate?.paneView(self, draggedTo: documentPoint, modifiers: event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        if activeDragRegion != nil {
            if dragStartedMoving {
                delegate?.paneViewDidEndDrag(self)
            } else if let click = pendingTabClick {
                if click.isClose {
                    delegate?.paneView(self, didCloseTab: click.panelId)
                } else {
                    delegate?.paneView(self, didSelectTab: click.panelId)
                }
            }
            pendingTabClick = nil
            activeDragRegion = nil
            dragStartedMoving = false
            return
        }
        super.mouseUp(with: event)
    }

    // MARK: Cursors

    override func resetCursorRects() {
        super.resetCursorRects()
        let band = Self.resizeBandWidth
        let width = bounds.width
        let height = bounds.height
        guard width > band * 2, height > band * 2 else { return }

        addCursorRect(
            CGRect(x: 0, y: band, width: band, height: height - band * 2),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            CGRect(x: width - band, y: band, width: band, height: height - band * 2),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            CGRect(x: band, y: 0, width: width - band * 2, height: band),
            cursor: .resizeUpDown
        )
        addCursorRect(
            CGRect(x: band, y: height - band, width: width - band * 2, height: band),
            cursor: .resizeUpDown
        )

        // Corner bands resize both axes, so they get the diagonal cursors.
        // Flipped view: y=0 is the top edge.
        let corner = Self.cornerBandWidth
        addCursorRect(CGRect(x: 0, y: 0, width: corner, height: corner), cursor: Self.diagonalCursorNWSE)
        addCursorRect(CGRect(x: width - corner, y: 0, width: corner, height: corner), cursor: Self.diagonalCursorNESW)
        addCursorRect(CGRect(x: 0, y: height - corner, width: corner, height: corner), cursor: Self.diagonalCursorNESW)
        addCursorRect(CGRect(x: width - corner, y: height - corner, width: corner, height: corner), cursor: Self.diagonalCursorNWSE)
    }

    // MARK: Diagonal resize cursors

    /// AppKit ships no public diagonal resize cursor; the window-resize ones
    /// are private. Resolve them by selector once, falling back to the
    /// nearest public cursor so we degrade rather than crash.
    private static let diagonalCursorNWSE: NSCursor = resolvePrivateCursor(
        "_windowResizeNorthWestSouthEastCursor", fallback: .resizeLeftRight)
    private static let diagonalCursorNESW: NSCursor = resolvePrivateCursor(
        "_windowResizeNorthEastSouthWestCursor", fallback: .resizeUpDown)

    private static func resolvePrivateCursor(_ name: String, fallback: NSCursor) -> NSCursor {
        let selector = Selector(name)
        if NSCursor.responds(to: selector),
           let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return fallback
    }
}
