public import AppKit
import CmuxCanvas

/// The AppKit root of the canvas layout: owns the scroll view, document,
/// pane views, content mounts, guides, drag/resize sessions, document
/// sizing, and the explicit offscreen-pane lifecycle.
///
/// The host's SwiftUI layer feeds it value snapshots (`CanvasPaneDescriptor`)
/// through `sync`; all durable geometry lives in ``CanvasModel``. Panel
/// content and theming stay host-owned behind ``CanvasPaneContentMounting``
/// and ``CanvasTheme``.
@MainActor
public final class CanvasRootView: NSView {
    private let model: CanvasModel
    private let callbacks: CanvasHostCallbacks
    private let themeProvider: () -> CanvasTheme
    private let scrollView: CanvasScrollView
    private let documentView = CanvasDocumentView()
    private let guidesView = CanvasGuidesView()

    private var paneViews: [UUID: CanvasPaneView] = [:]
    private var mounts: [UUID: any CanvasPaneContentMounting] = [:]
    private var renderingByPanelId: [UUID: Bool] = [:]
    private var isWorkspaceVisible = true
    /// Canvas coordinates of the document view's (0,0).
    private var documentOriginInCanvas: CGPoint = .zero
    private var dragSession: DragSession?
    private var overviewRestore: (magnification: CGFloat, origin: CGPoint)?
    private var clipBoundsObserver: (any NSObjectProtocol)?
    private var commandScrollMonitor: Any?
    private var hasPlacedInitialViewport = false

    /// Extra viewport fraction kept rendering around the visible rect so
    /// panes don't flicker on at the edge mid-flick.
    private static let lifecycleMarginFraction: CGFloat = 0.5
    private static let revealMargin: CGFloat = 24
    private static let overviewPadding: CGFloat = 48

    private struct DragSession {
        let panelId: UUID
        let region: CanvasPaneHitRegion
        let originalFrame: CGRect
        let startPoint: CGPoint
        var lastFrame: CGRect
    }

    public init(
        model: CanvasModel,
        callbacks: CanvasHostCallbacks,
        themeProvider: @escaping () -> CanvasTheme
    ) {
        self.model = model
        self.callbacks = callbacks
        self.themeProvider = themeProvider
        self.scrollView = CanvasScrollView(documentView: documentView)
        super.init(frame: .zero)
        applyTheme()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        guidesView.autoresizingMask = [.width, .height]
        documentView.addSubview(guidesView)

        // Platform seam: clip-view bounds changes are how AppKit reports
        // scrolling; this drives the explicit pane lifecycle.
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewportDidScroll()
            }
        }
        model.viewport = self
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    private func applyTheme() {
        let theme = themeProvider()
        scrollView.backgroundColor = theme.canvasBackground
        documentView.canvasBackground = theme.canvasBackground
        for paneView in paneViews.values {
            paneView.paneBackground = theme.paneBackground
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    // MARK: Command-scroll canvas panning

    /// Pane content (terminals especially) consumes plain scroll events, so
    /// panning stalls whenever the cursor sits over a pane. Holding Command
    /// routes the scroll to the canvas regardless of what is underneath —
    /// the monitor intercepts before hit-testing reaches the content.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeCommandScrollMonitor()
        } else {
            installCommandScrollMonitor()
        }
    }

    private func installCommandScrollMonitor() {
        guard commandScrollMonitor == nil else { return }
        commandScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window,
                  event.modifierFlags.contains(.command) else {
                return event
            }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }
            self.scrollView.scrollWheel(with: event)
            return nil
        }
    }

    private func removeCommandScrollMonitor() {
        if let commandScrollMonitor {
            NSEvent.removeMonitor(commandScrollMonitor)
        }
        commandScrollMonitor = nil
    }

    /// Releases mounted content (terminals go back to the portal system) and
    /// observers. Called when the workspace leaves canvas mode.
    public func teardown() {
        for (_, mount) in mounts {
            mount.unmount()
        }
        mounts.removeAll()
        paneViews.values.forEach { $0.removeFromSuperview() }
        paneViews.removeAll()
        renderingByPanelId.removeAll()
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
        clipBoundsObserver = nil
        removeCommandScrollMonitor()
        if model.viewport === self {
            model.viewport = nil
        }
    }

    // MARK: Sync

    /// Reconciles the canvas against the host's current panel set.
    public func sync(descriptors: [CanvasPaneDescriptor], focusedPanelId: UUID?, isWorkspaceVisible: Bool) {
        self.isWorkspaceVisible = isWorkspaceVisible
        let added = model.syncPanes(
            panelIds: descriptors.map(\.id),
            focusedPanelId: focusedPanelId
        )

        let descriptorIds = Set(descriptors.map(\.id))
        for (panelId, paneView) in paneViews where !descriptorIds.contains(panelId) {
            mounts[panelId]?.unmount()
            mounts[panelId] = nil
            renderingByPanelId[panelId] = nil
            paneView.removeFromSuperview()
            paneViews[panelId] = nil
        }

        applyTheme()
        for descriptor in descriptors {
            if paneViews[descriptor.id] == nil {
                let paneView = CanvasPaneView(panelId: descriptor.id)
                paneView.delegate = self
                paneView.paneBackground = themeProvider().paneBackground
                documentView.addSubview(paneView)
                paneViews[descriptor.id] = paneView
                mounts[descriptor.id] = descriptor.makeMount(paneView.contentContainer)
            }
            paneViews[descriptor.id]?.updateChrome(descriptor.chrome)
        }

        applyZOrder()
        recomputeDocumentGeometry()
        applyAllPaneFrames()
        updateLifecycle()

        if !hasPlacedInitialViewport, !model.layout.isEmpty {
            hasPlacedInitialViewport = true
            if let focusedPanelId, model.frame(of: focusedPanelId) != nil {
                revealPane(focusedPanelId, animated: false)
            } else if let bounds = model.contentBounds {
                scrollCanvasPointToTopLeft(
                    CGPoint(x: bounds.minX - Self.revealMargin, y: bounds.minY - Self.revealMargin),
                    animated: false
                )
            }
        } else if let revealTarget = added.last {
            revealPane(revealTarget, animated: true)
        }
    }


    private func applyZOrder() {
        for paneID in model.layout.paneIDs {
            if let paneView = paneViews[paneID.rawValue] {
                documentView.addSubview(paneView, positioned: .above, relativeTo: nil)
            }
        }
        documentView.addSubview(guidesView, positioned: .above, relativeTo: nil)
    }

    private func applyAllPaneFrames() {
        for (panelId, paneView) in paneViews {
            guard dragSession?.panelId != panelId else { continue }
            if let frame = model.frame(of: panelId) {
                paneView.frame = documentRect(fromCanvas: frame)
            }
        }
    }

    // MARK: Coordinate spaces

    private func documentRect(fromCanvas rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -documentOriginInCanvas.x, dy: -documentOriginInCanvas.y)
    }

    private func canvasRect(fromDocument rect: CGRect) -> CGRect {
        rect.offsetBy(dx: documentOriginInCanvas.x, dy: documentOriginInCanvas.y)
    }

    /// Sizes the document around the content with a viewport-sized margin on
    /// every side, shifting the scroll origin so nothing moves on screen.
    private func recomputeDocumentGeometry() {
        let clipSize = scrollView.contentView.bounds.size
        let marginX = max(clipSize.width, 500)
        let marginY = max(clipSize.height, 400)
        let content = model.contentBounds ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let docRectInCanvas = content.insetBy(dx: -marginX, dy: -marginY)

        let oldOrigin = documentOriginInCanvas
        documentOriginInCanvas = docRectInCanvas.origin
        documentView.canvasToDocumentOffset = CGPoint(
            x: -documentOriginInCanvas.x,
            y: -documentOriginInCanvas.y
        )
        guidesView.canvasToDocumentOffset = documentView.canvasToDocumentOffset

        let delta = CGPoint(
            x: oldOrigin.x - documentOriginInCanvas.x,
            y: oldOrigin.y - documentOriginInCanvas.y
        )
        documentView.setFrameSize(docRectInCanvas.size)
        guidesView.frame = documentView.bounds
        if delta != .zero, hasPlacedInitialViewport {
            let clipOrigin = scrollView.contentView.bounds.origin
            scrollView.contentView.setBoundsOrigin(CGPoint(
                x: clipOrigin.x + delta.x,
                y: clipOrigin.y + delta.y
            ))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: Lifecycle

    private func viewportDidScroll() {
        updateLifecycle()
        callbacks.onViewportGeometryChanged(window)
    }

    public override func layout() {
        super.layout()
        recomputeDocumentGeometry()
        applyAllPaneFrames()
        updateLifecycle()
        callbacks.onViewportGeometryChanged(window)
    }

    /// Explicit pane lifecycle: panes within the visible rect (plus margin)
    /// render; everything else stops (Ghostty occlusion). Frames never change
    /// while offscreen, so re-entry never reflows.
    private func updateLifecycle() {
        let visible = scrollView.contentView.documentVisibleRect
        let margin = CGSize(
            width: visible.width * Self.lifecycleMarginFraction,
            height: visible.height * Self.lifecycleMarginFraction
        )
        let renderRect = visible.insetBy(dx: -margin.width, dy: -margin.height)
        for (panelId, paneView) in paneViews {
            let rendering = isWorkspaceVisible && renderRect.intersects(paneView.frame)
            if renderingByPanelId[panelId] != rendering {
                renderingByPanelId[panelId] = rendering
                mounts[panelId]?.setRendering(rendering)
            }
        }
    }

    // MARK: Viewport math helpers

    private func scrollCanvasPointToTopLeft(_ canvasPoint: CGPoint, animated: Bool) {
        let target = CGPoint(
            x: canvasPoint.x - documentOriginInCanvas.x,
            y: canvasPoint.y - documentOriginInCanvas.y
        )
        setClipOrigin(target, animated: animated)
    }

    private func setClipOrigin(_ origin: CGPoint, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

// MARK: - CanvasViewportControlling

extension CanvasRootView: CanvasViewportControlling {
    public func modelDidChangeExternally(animated: Bool) {
        applyZOrder()
        recomputeDocumentGeometry()
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                for (panelId, paneView) in paneViews {
                    if let frame = model.frame(of: panelId) {
                        paneView.animator().frame = documentRect(fromCanvas: frame)
                    }
                }
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.callbacks.onViewportGeometryChanged(self.window)
            })
        } else {
            applyAllPaneFrames()
        }
        updateLifecycle()
        callbacks.onLayoutChanged()
        callbacks.onViewportGeometryChanged(window)
    }

    public func revealPane(_ panelId: UUID, animated: Bool) {
        guard let frame = model.frame(of: panelId) else { return }
        let docFrame = documentRect(fromCanvas: frame)
        let visible = scrollView.contentView.documentVisibleRect
        let origin = CanvasViewportMath().originToReveal(
            CanvasRect(docFrame),
            viewportOrigin: CanvasPoint(visible.origin),
            viewportSize: CanvasSize(visible.size),
            margin: Self.revealMargin
        )
        guard origin.cgPoint != visible.origin else { return }
        setClipOrigin(origin.cgPoint, animated: animated)
    }

    public func zoom(by factor: CGFloat) {
        // An explicit zoom invalidates the overview round-trip restore.
        overviewRestore = nil
        let target = min(
            max(scrollView.magnification * factor, scrollView.minMagnification),
            scrollView.maxMagnification
        )
        setMagnification(target)
    }

    public func resetZoom() {
        overviewRestore = nil
        setMagnification(1.0)
    }

    /// Animates to `magnification`, keeping the current viewport center
    /// fixed (explicit origin math; `setMagnification(centeredAt:)` drifts
    /// on large deltas).
    private func setMagnification(_ magnification: CGFloat) {
        guard magnification != scrollView.magnification else { return }
        let visible = scrollView.contentView.documentVisibleRect
        let center = CGPoint(x: visible.midX, y: visible.midY)
        let viewportSize = scrollView.contentSize
        let clipSize = CGSize(
            width: viewportSize.width / magnification,
            height: viewportSize.height / magnification
        )
        let targetOrigin = CGPoint(
            x: center.x - clipSize.width / 2,
            y: center.y - clipSize.height / 2
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            scrollView.animator().magnification = magnification
            scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    public func toggleOverview() {
        if let restore = overviewRestore {
            overviewRestore = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                scrollView.animator().magnification = restore.magnification
                scrollView.contentView.animator().setBoundsOrigin(restore.origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            return
        }
        guard let content = model.contentBounds else { return }
        overviewRestore = (scrollView.magnification, scrollView.contentView.bounds.origin)
        let viewportSize = scrollView.contentSize
        let fit = CGFloat(CanvasViewportMath().magnificationToFit(
            CanvasRect(content),
            in: CanvasSize(viewportSize),
            padding: Self.overviewPadding,
            range: Double(scrollView.minMagnification)...Double(scrollView.maxMagnification)
        ))
        // Anchor explicitly: after magnification `fit`, the clip's bounds are
        // viewport/fit in document coordinates; centering the content means
        // origin = contentCenter - clipSize/2. setMagnification(centeredAt:)
        // alone lands off-center when the magnification change is large.
        let docCenter = documentRect(fromCanvas: content).canvasCenter
        let clipSize = CGSize(width: viewportSize.width / fit, height: viewportSize.height / fit)
        let targetOrigin = CGPoint(
            x: docCenter.x - clipSize.width / 2,
            y: docCenter.y - clipSize.height / 2
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            scrollView.animator().magnification = fit
            scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

// MARK: - CanvasPaneViewDelegate

extension CanvasRootView: CanvasPaneViewDelegate {
    func paneView(_ view: CanvasPaneView, mouseDownAt documentPoint: CGPoint, region: CanvasPaneHitRegion) {
        guard let frame = model.frame(of: view.panelId) else { return }
        dragSession = DragSession(
            panelId: view.panelId,
            region: region,
            originalFrame: frame,
            startPoint: documentPoint,
            lastFrame: frame
        )
        model.bringToFront(view.panelId)
        applyZOrder()
    }

    func paneView(_ view: CanvasPaneView, draggedTo documentPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var session = dragSession, session.panelId == view.panelId else { return }
        let dx = documentPoint.x - session.startPoint.x
        let dy = documentPoint.y - session.startPoint.y
        // Holding Command suspends snapping for free-form placement.
        let snapping = !modifiers.contains(.command)

        let result: CanvasSnapResult
        switch session.region {
        case .titleBar:
            let proposed = session.originalFrame.offsetBy(dx: dx, dy: dy)
            result = model.snapForMove(proposed: proposed, movingPanelId: session.panelId, snapping: snapping)
        case .resize(let edges):
            var proposed = session.originalFrame
            if edges.contains(.left) {
                proposed.origin.x += dx
                proposed.size.width = max(1, proposed.size.width - dx)
            } else if edges.contains(.right) {
                proposed.size.width = max(1, proposed.size.width + dx)
            }
            if edges.contains(.top) {
                proposed.origin.y += dy
                proposed.size.height = max(1, proposed.size.height - dy)
            } else if edges.contains(.bottom) {
                proposed.size.height = max(1, proposed.size.height + dy)
            }
            result = model.snapForResize(
                proposed: proposed,
                edges: edges,
                panelId: session.panelId,
                snapping: snapping
            )
        }

        session.lastFrame = result.frame.cgRect
        dragSession = session
        view.frame = documentRect(fromCanvas: session.lastFrame)
        guidesView.setGuides(result.guides)
        callbacks.onViewportGeometryChanged(window)
    }

    func paneViewDidEndDrag(_ view: CanvasPaneView) {
        guard let session = dragSession, session.panelId == view.panelId else { return }
        dragSession = nil
        guidesView.setGuides([])
        model.setFrame(session.lastFrame, for: session.panelId)
        recomputeDocumentGeometry()
        applyAllPaneFrames()
        updateLifecycle()
        callbacks.onLayoutChanged()
        callbacks.onViewportGeometryChanged(window)
    }

    func paneViewDidRequestClose(_ view: CanvasPaneView) {
        callbacks.onClosePanel(view.panelId)
    }

    func paneViewDidRequestFocus(_ view: CanvasPaneView) {
        callbacks.onFocusPanel(view.panelId)
    }
}
