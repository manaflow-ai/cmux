import AppKit
import SwiftUI
import CmuxCanvas

/// Delegate through which a pane view reports gestures to the canvas root.
@MainActor
protocol CanvasPaneViewDelegate: AnyObject {
    func paneView(_ view: CanvasPaneView, mouseDownAt documentPoint: CGPoint, region: CanvasPaneHitRegion)
    func paneView(_ view: CanvasPaneView, draggedTo documentPoint: CGPoint, modifiers: NSEvent.ModifierFlags)
    func paneViewDidEndDrag(_ view: CanvasPaneView)
    /// Option+drag on a tab of a multi-tab pane: tear the tab out into its
    /// own pane and continue the drag with that new pane.
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
    /// Pending click target resolved at mouse-down, fired at mouse-up when
    /// no drag started.
    private var pendingTabClick: (panelId: UUID, isClose: Bool)?

    /// Pane fill behind the content, resolved by the host through
    /// ``CanvasTheme``.
    var paneBackground: NSColor = .windowBackgroundColor {
        didSet {
            guard paneBackground != oldValue else { return }
            applyChromeColors()
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
            onHitRegionsChanged: { _ in }
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

    /// Updates the tab strip and focus ring. No-op when nothing changed.
    func updateChrome(_ chrome: CanvasPaneChrome) {
        guard chrome != self.chrome else { return }
        self.chrome = chrome
        titleBarHost.rootView = CanvasPaneTitleBarView(
            chrome: chrome,
            onHitRegionsChanged: { [weak self] regions in
                self?.tabHitRegions = regions
            }
        )
        applyChromeColors()
    }

    private func applyChromeColors() {
        layer?.borderColor = chrome.isFocused
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.cgColor
        layer?.borderWidth = chrome.isFocused ? 2 : 1
        layer?.backgroundColor = paneBackground.cgColor
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
            delegate?.paneViewDidRequestFocus(self)
            super.mouseDown(with: event)
            return
        }
        pendingTabClick = nil
        if case .titleBar = region {
            let barPoint = titleBarHost.convert(event.locationInWindow, from: nil)
            if let (panelId, _) = tabHitRegions.closeFrames.first(where: { $0.value.contains(barPoint) }) {
                pendingTabClick = (panelId, true)
            } else if let (panelId, _) = tabHitRegions.tabFrames.first(where: { $0.value.contains(barPoint) }) {
                pendingTabClick = (panelId, false)
            }
        }
        guard let documentView = superview else { return }
        let documentPoint = documentView.convert(event.locationInWindow, from: nil)
        // Option+drag on a tab tears it out into its own pane; the root
        // starts a drag session for the new pane and our tracking loop keeps
        // feeding it.
        if case .titleBar = region,
           event.modifierFlags.contains(.option),
           let click = pendingTabClick, !click.isClose {
            pendingTabClick = nil
            activeDragRegion = region
            dragStartedMoving = true
            dragStartDocumentPoint = documentPoint
            delegate?.paneView(self, requestTearOutTab: click.panelId, atDocumentPoint: documentPoint)
            return
        }
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
