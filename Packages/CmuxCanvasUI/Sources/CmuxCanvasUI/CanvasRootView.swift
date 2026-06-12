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

    private var paneViews: [CanvasPaneID: CanvasPaneView] = [:]
    /// One mount per pane: its selected tab's content. Keyed by panel id.
    private var mounts: [UUID: any CanvasPaneContentMounting] = [:]
    /// The panel currently mounted in each pane.
    private var mountedPanelByPane: [CanvasPaneID: UUID] = [:]
    /// The latest descriptors, by panel id, for mount/chrome lookups.
    private var descriptorsByPanelId: [UUID: CanvasPaneDescriptor] = [:]
    private var renderingByPane: [CanvasPaneID: Bool] = [:]
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
        let paneID: CanvasPaneID
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
        mountedPanelByPane.removeAll()
        descriptorsByPanelId.removeAll()
        paneViews.values.forEach { $0.removeFromSuperview() }
        paneViews.removeAll()
        renderingByPane.removeAll()
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

    /// Reconciles the canvas against the host's current panel set: pane
    /// views per model pane, one mounted content per pane (the selected
    /// tab), chrome from the descriptors.
    public func sync(descriptors: [CanvasPaneDescriptor], focusedPanelId: UUID?, isWorkspaceVisible: Bool) {
        self.isWorkspaceVisible = isWorkspaceVisible
        let added = model.syncPanes(
            panelIds: descriptors.map(\.id),
            focusedPanelId: focusedPanelId
        )
        descriptorsByPanelId = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

        reconcilePanes()
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


    /// Creates/removes pane views to match the model's pane set and brings
    /// each pane's mount and chrome up to date from the cached descriptors.
    /// Runs on every sync and after external model mutations (socket verbs).
    private func reconcilePanes() {
        let livePaneIDs = Set(model.layout.paneIDs)
        for (paneID, paneView) in paneViews where !livePaneIDs.contains(paneID) {
            if let mounted = mountedPanelByPane[paneID] {
                mounts[mounted]?.unmount()
                mounts[mounted] = nil
            }
            mountedPanelByPane[paneID] = nil
            renderingByPane[paneID] = nil
            paneView.removeFromSuperview()
            paneViews[paneID] = nil
        }

        applyTheme()
        for pane in model.layout.panes {
            let paneView: CanvasPaneView
            if let existing = paneViews[pane.id] {
                paneView = existing
            } else {
                paneView = CanvasPaneView(paneID: pane.id)
                paneView.delegate = self
                paneView.paneBackground = themeProvider().paneBackground
                documentView.addSubview(paneView)
                paneViews[pane.id] = paneView
            }
            reconcileMount(for: pane, in: paneView)
            paneView.updateChrome(chrome(for: pane))
        }
    }

    /// Mounts the pane's selected tab, unmounting whatever was mounted
    /// before. Content mounts exactly while it is the visible tab.
    private func reconcileMount(for pane: CanvasPane, in paneView: CanvasPaneView) {
        let selected = pane.selectedPanelId.rawValue
        let mounted = mountedPanelByPane[pane.id]
        guard mounted != selected else { return }
        if let mounted {
            mounts[mounted]?.unmount()
            mounts[mounted] = nil
        }
        if let descriptor = descriptorsByPanelId[selected] {
            mounts[selected] = descriptor.makeMount(paneView.contentContainer)
            mountedPanelByPane[pane.id] = selected
            // A fresh mount starts in the pane's current lifecycle state.
            if renderingByPane[pane.id] == false {
                mounts[selected]?.setRendering(false)
            }
        } else {
            mountedPanelByPane[pane.id] = nil
        }
    }

    /// Builds the pane's strip chrome from the latest descriptors.
    private func chrome(for pane: CanvasPane) -> CanvasPaneChrome {
        let tabs = pane.panelIds.compactMap { descriptorsByPanelId[$0.rawValue]?.tab }
        let isFocused = pane.panelIds.contains { descriptorsByPanelId[$0.rawValue]?.isFocused == true }
        let closeLabel = descriptorsByPanelId[pane.selectedPanelId.rawValue]?.closeActionLabel
            ?? descriptorsByPanelId.values.first?.closeActionLabel
            ?? ""
        return CanvasPaneChrome(
            tabs: tabs,
            selectedTabId: pane.selectedPanelId.rawValue,
            isFocused: isFocused,
            closeActionLabel: closeLabel
        )
    }

    private func applyZOrder() {
        for paneID in model.layout.paneIDs {
            if let paneView = paneViews[paneID] {
                documentView.addSubview(paneView, positioned: .above, relativeTo: nil)
            }
        }
        documentView.addSubview(guidesView, positioned: .above, relativeTo: nil)
    }

    private func applyAllPaneFrames() {
        for (paneID, paneView) in paneViews {
            guard dragSession?.paneID != paneID else { continue }
            if let frame = model.layout.frame(of: paneID)?.cgRect {
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
        for (paneID, paneView) in paneViews {
            let rendering = isWorkspaceVisible && renderRect.intersects(paneView.frame)
            if renderingByPane[paneID] != rendering {
                renderingByPane[paneID] = rendering
                if let mounted = mountedPanelByPane[paneID] {
                    mounts[mounted]?.setRendering(rendering)
                }
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
        reconcilePanes()
        applyZOrder()
        recomputeDocumentGeometry()
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                for (paneID, paneView) in paneViews {
                    if let frame = model.layout.frame(of: paneID)?.cgRect {
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
    /// The selected panel of a pane view, used for panel-keyed model calls.
    private func selectedPanelId(of view: CanvasPaneView) -> UUID? {
        model.layout.selectedPanelId(in: view.paneID)?.rawValue
    }

    func paneView(_ view: CanvasPaneView, mouseDownAt documentPoint: CGPoint, region: CanvasPaneHitRegion) {
        guard let frame = model.layout.frame(of: view.paneID)?.cgRect else { return }
        dragSession = DragSession(
            paneID: view.paneID,
            region: region,
            originalFrame: frame,
            startPoint: documentPoint,
            lastFrame: frame
        )
        if let panelId = selectedPanelId(of: view) {
            model.bringToFront(panelId)
        }
        applyZOrder()
    }

    func paneView(_ view: CanvasPaneView, draggedTo documentPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var session = dragSession, session.paneID == view.paneID,
              let panelId = selectedPanelId(of: view) else { return }
        let dx = documentPoint.x - session.startPoint.x
        let dy = documentPoint.y - session.startPoint.y
        // Holding Command suspends snapping for free-form placement.
        let snapping = !modifiers.contains(.command)

        let result: CanvasSnapResult
        switch session.region {
        case .titleBar:
            let proposed = session.originalFrame.offsetBy(dx: dx, dy: dy)
            result = model.snapForMove(proposed: proposed, movingPanelId: panelId, snapping: snapping)
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
                panelId: panelId,
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
        guard let session = dragSession, session.paneID == view.paneID,
              let panelId = selectedPanelId(of: view) else { return }
        dragSession = nil
        guidesView.setGuides([])
        model.setFrame(session.lastFrame, for: panelId)
        recomputeDocumentGeometry()
        applyAllPaneFrames()
        updateLifecycle()
        callbacks.onLayoutChanged()
        callbacks.onViewportGeometryChanged(window)
    }

    func paneView(_ view: CanvasPaneView, didSelectTab panelId: UUID) {
        model.selectPanel(panelId)
        if let pane = model.layout.panes.first(where: { $0.id == view.paneID }) {
            reconcileMount(for: pane, in: view)
            view.updateChrome(chrome(for: pane))
        }
        callbacks.onFocusPanel(panelId)
        callbacks.onViewportGeometryChanged(window)
    }

    func paneView(_ view: CanvasPaneView, didCloseTab panelId: UUID) {
        callbacks.onClosePanel(panelId)
    }

    func paneViewDidRequestFocus(_ view: CanvasPaneView) {
        if let panelId = selectedPanelId(of: view) {
            callbacks.onFocusPanel(panelId)
        }
    }
}
