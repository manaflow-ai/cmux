import AppKit
import SwiftUI
import CmuxCanvas

/// Delegate through which a pane view reports gestures to the canvas root.
@MainActor
protocol CanvasPaneViewDelegate: AnyObject {
    func paneView(_ view: CanvasPaneView, mouseDownAt documentPoint: CGPoint, region: CanvasPaneHitRegion)
    func paneView(_ view: CanvasPaneView, draggedTo documentPoint: CGPoint, modifiers: NSEvent.ModifierFlags)
    func paneViewDidEndDrag(_ view: CanvasPaneView)
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
            onSelectTab: { _ in },
            onCloseTab: { _ in }
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
            onSelectTab: { [weak self] panelId in
                guard let self else { return }
                self.delegate?.paneView(self, didSelectTab: panelId)
            },
            onCloseTab: { [weak self] panelId in
                guard let self else { return }
                self.delegate?.paneView(self, didCloseTab: panelId)
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

    /// Route border-band clicks to the pane itself even when they land over
    /// the title strip or content edges, so resize always wins at the rim.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        guard result != nil, result !== self else { return result }
        let local = convert(point, from: superview)
        if case .resize = hitRegion(at: local) {
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
        guard let documentView = superview else { return }
        activeDragRegion = region
        dragStartedMoving = false
        dragStartDocumentPoint = documentView.convert(event.locationInWindow, from: nil)
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
            }
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
    }
}
