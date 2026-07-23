public import AppKit
import SwiftUI
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
    let model: CanvasModel
    let callbacks: CanvasHostCallbacks
    private let themeProvider: () -> CanvasTheme
    let minimapAutoHideScheduler: CanvasMinimapAutoHideScheduler
    /// Pre-localized text for the Command+scroll discovery hint.
    let commandScrollHintText: String
    let scrollView: CanvasScrollView
    let documentView = CanvasDocumentView()
    let guidesView = CanvasGuidesView()
    let minimapView = CanvasMinimapView()
    var isMinimapInteractionActive = false
    var paneViews: [CanvasPaneID: CanvasPaneView] = [:]
    /// One mount per pane: its selected tab's content. Keyed by panel id.
    private var mounts: [UUID: any CanvasPaneContentMounting] = [:]
    /// The panel currently mounted in each pane.
    private var mountedPanelByPane: [CanvasPaneID: UUID] = [:]
    /// The latest descriptors, by panel id, for mount/chrome lookups.
    var descriptorsByPanelId: [UUID: CanvasPaneDescriptor] = [:]
    private var renderingByPane: [CanvasPaneID: Bool] = [:]
    var isWorkspaceVisible = true
    /// Canvas coordinates of the document view's (0,0).
    var documentOriginInCanvas: CGPoint = .zero
    var dragSession: DragSession?
    var overviewRestore: (magnification: CGFloat, origin: CGPoint)?
    private var clipBoundsObserver: (any NSObjectProtocol)?
    private var scrollSettleObservers: [any NSObjectProtocol] = []
    var commandScrollMonitor: Any?
    /// Debounced settle after option+scroll zoom (which, unlike a trackpad
    /// pinch, never fires `didEndLiveMagnify`), so portals re-anchor once the
    /// zoom gesture stops.
    var zoomSettleTask: Task<Void, Never>?
    var paneBodyFocusMonitor: Any?
    private var hasPlacedInitialViewport = false
    /// One-per-session throttle for the Command+scroll discovery hint.
    static var didShowCommandScrollHintThisSession = false
    var commandScrollHintTask: Task<Void, Never>?
    var commandScrollHintHost: NSHostingView<CanvasCommandScrollHint>?
    /// A saved viewport waiting for contentSize to settle. Cleared when applied.
    private var pendingViewportRestore: (canvasCenter: CGPoint, magnification: CGFloat)?
    var isDiscreteZoomAnimationActive = false
    var discreteZoomAnimationGeneration: UInt64 = 0
    var shouldReduceMotionForDiscreteZoom: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// True while programmatically applying a saved viewport, so the scroll
    /// events that causes don't overwrite the saved value with transients.
    private var isApplyingSavedViewport = false
    /// Extra viewport fraction kept rendering around the visible rect so
    /// panes don't flicker on at the edge mid-flick.
    private static let lifecycleMarginFraction: CGFloat = 0.5
    static let dragContentSuppressionMagnificationThreshold: CGFloat = 0.5
    static let revealMargin: CGFloat = 24
    static let overviewPadding: CGFloat = 48
    struct DragSession {
        let paneID: CanvasPaneID
        let region: CanvasPaneHitRegion
        let originalFrame: CGRect
        let startPoint: CGPoint
        var lastFrame: CGRect
        var lastPoint: CGPoint = .zero
    }

    init<C: Clock & Sendable>(
        model: CanvasModel,
        commandScrollHintText: String,
        minimapAccessibilityLabel: String,
        minimapAccessibilityHelp: String,
        callbacks: CanvasHostCallbacks,
        themeProvider: @escaping () -> CanvasTheme, minimapClock: C
    ) where C.Duration == Duration {
        self.model = model
        self.callbacks = callbacks
        self.commandScrollHintText = commandScrollHintText
        self.themeProvider = themeProvider
        self.minimapAutoHideScheduler = CanvasMinimapAutoHideScheduler(clock: minimapClock)
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
        configureMinimap(accessibilityLabel: minimapAccessibilityLabel, accessibilityHelp: minimapAccessibilityHelp)
        resetMinimapVisibility()

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
        scrollSettleObservers = [
            NSScrollView.didEndLiveScrollNotification,
            NSScrollView.didEndLiveMagnifyNotification,
        ].map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: scrollView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.callbacks.onViewportSettled(self.window)
                }
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
            removePaneBodyFocusMonitor()
            detachMinimapOverlay()
        } else {
            installCommandScrollMonitor()
            installPaneBodyFocusMonitor()
            syncMinimapOverlayHost()
        }
    }

    /// Releases mounted content (terminals go back to the portal system) and
    /// observers. Called when the workspace leaves canvas mode.
    public func teardown() {
        // Capture the final viewport before the view goes away so returning
        // to this workspace restores the exact spot.
        saveViewportToModel()
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
        scrollSettleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        scrollSettleObservers = []
        cancelDiscreteZoomAnimation()
        commandScrollHintTask?.cancel()
        commandScrollHintTask = nil
        resetMinimapVisibility()
        zoomSettleTask?.cancel()
        zoomSettleTask = nil
        commandScrollHintHost?.removeFromSuperview()
        commandScrollHintHost = nil
        minimapView.onCenterChanged = nil
        minimapView.onCenterSettled = nil
        minimapView.onScrollWheel = nil
        minimapView.onInteractionBegan = nil
        minimapView.onInteractionEnded = nil
        removeCommandScrollMonitor()
        removePaneBodyFocusMonitor()
        if model.viewport === self {
            model.viewport = nil
        }
    }

    // MARK: Sync

    /// Reconciles the canvas against the host's current panel set: pane
    /// views per model pane, one mounted content per pane (the selected
    /// tab), chrome from the descriptors.
    public func sync(descriptors: [CanvasPaneDescriptor], focusedPanelId: UUID?, isWorkspaceVisible: Bool) {
        let becameVisible = isWorkspaceVisible && !self.isWorkspaceVisible
        self.isWorkspaceVisible = isWorkspaceVisible
        let added = model.syncPanes(
            panelIds: descriptors.map(\.id),
            focusedPanelId: focusedPanelId
        )
        descriptorsByPanelId = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

        // The focused pane always rides to the front, regardless of which
        // entrypoint moved focus (click, keyboard, palette, socket).
        if let focusedPanelId,
           let focusedPane = model.paneID(containing: focusedPanelId),
           model.layout.paneIDs.last != focusedPane {
            model.bringToFront(focusedPanelId)
        }
        reconcilePanes()
        applyZOrder()
        recomputeDocumentGeometry()
        applyAllPaneFrames()
        updateLifecycle()
        updateMinimap()

        if !hasPlacedInitialViewport, !model.layout.isEmpty {
            hasPlacedInitialViewport = true
            if let saved = model.savedViewport {
                // Returning to a workspace: restore the exact spot + zoom once
                // the viewport is sized (deferred via the pending mechanism).
                pendingViewportRestore = saved
                applyPendingViewportRestoreIfPossible()
            } else if let focusedPanelId, model.frame(of: focusedPanelId) != nil {
                revealPane(focusedPanelId, animated: false)
            } else if let bounds = model.contentBounds {
                scrollCanvasPointToTopLeft(
                    CGPoint(x: bounds.minX - Self.revealMargin, y: bounds.minY - Self.revealMargin),
                    animated: false
                )
            }
        } else if becameVisible, let saved = model.savedViewport {
            // The host keeps canvas views alive across workspace switches and
            // AppKit can reset the clip origin while hidden; re-apply the saved
            // viewport so switching back lands exactly where the user left off.
            pendingViewportRestore = saved
            applyPendingViewportRestoreIfPossible()
        } else if let revealTarget = added.last {
            revealPane(revealTarget, animated: true)
        }
    }

    /// Creates/removes pane views to match the model's pane set and brings
    /// each pane's mount and chrome up to date from the cached descriptors.
    /// Runs on every sync and after external model mutations (socket verbs).
    func reconcilePanes() {
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
            updateMountState(for: pane)
            paneView.updateChrome(chrome(for: pane))
        }
    }

    /// Mounts the pane's selected tab, unmounting whatever was mounted
    /// before. Content mounts exactly while it is the visible tab.
    func reconcileMount(for pane: CanvasPane, in paneView: CanvasPaneView) {
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

    /// Lets the host apply panel-specific presentation state to the pane's
    /// selected content without exposing host panel types to the canvas package.
    func updateMountState(for pane: CanvasPane) {
        let selected = pane.selectedPanelId.rawValue
        guard let mount = mounts[selected],
              let descriptor = descriptorsByPanelId[selected] else { return }
        descriptor.updateMount(mount)
    }

    func applyZOrder() {
        for paneID in model.layout.paneIDs {
            if let paneView = paneViews[paneID] {
                documentView.addSubview(paneView, positioned: .above, relativeTo: nil)
            }
        }
        documentView.addSubview(guidesView, positioned: .above, relativeTo: nil)
    }

    func applyAllPaneFrames() {
        for (paneID, paneView) in paneViews {
            guard dragSession?.paneID != paneID else { continue }
            if let frame = model.layout.frame(of: paneID)?.cgRect {
                paneView.frame = documentRect(fromCanvas: frame)
            }
        }
    }

    // MARK: Coordinate spaces

    func documentRect(fromCanvas rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -documentOriginInCanvas.x, dy: -documentOriginInCanvas.y)
    }

    func canvasRect(fromDocument rect: CGRect) -> CGRect {
        rect.offsetBy(dx: documentOriginInCanvas.x, dy: documentOriginInCanvas.y)
    }

    /// Sizes the document around the content with a viewport-sized margin on
    /// every side, shifting the scroll origin so nothing moves on screen.
    func recomputeDocumentGeometry() {
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
        updateMinimap(reveal: hasPlacedInitialViewport && !isApplyingSavedViewport)
        saveViewportToModel()
        callbacks.onViewportGeometryChanged(window)
    }

    /// Persists the current viewport center (canvas coords) + magnification
    /// into the model so a later remount can restore the user's exact spot.
    func saveViewportToModel() {
        guard hasPlacedInitialViewport else { return }
        // Don't capture transients caused by our own restore, or while a
        // restore is still pending (the clip is at a stale/default origin).
        guard !isApplyingSavedViewport, pendingViewportRestore == nil else { return }
        let visible = scrollView.contentView.documentVisibleRect
        guard visible.width > 1, visible.height > 1 else { return }
        let center = CGPoint(
            x: visible.midX + documentOriginInCanvas.x,
            y: visible.midY + documentOriginInCanvas.y
        )
        model.savedViewport = (canvasCenter: center, magnification: scrollView.magnification)
    }

    /// Applies a pending saved viewport once the scroll view is laid out.
    /// Returns false (keeping it pending) while contentSize is degenerate, so
    /// a later layout pass retries — restoring against a 0-sized or
    /// mid-layout viewport produces a garbage origin.
    private func applyPendingViewportRestoreIfPossible() {
        guard let saved = pendingViewportRestore else { return }
        let viewportSize = scrollView.contentSize
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        let mag = min(max(saved.magnification, scrollView.minMagnification), scrollView.maxMagnification)
        let clipSize = CGSize(width: viewportSize.width / mag, height: viewportSize.height / mag)
        let origin = CGPoint(
            x: saved.canvasCenter.x - documentOriginInCanvas.x - clipSize.width / 2,
            y: saved.canvasCenter.y - documentOriginInCanvas.y - clipSize.height / 2
        )
        isApplyingSavedViewport = true
        scrollView.magnification = mag
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isApplyingSavedViewport = false
        pendingViewportRestore = nil
    }

    public override func layout() {
        super.layout()
        recomputeDocumentGeometry()
        applyAllPaneFrames()
        // A restore deferred for a not-yet-sized viewport retries here, once
        // layout has given the scroll view real bounds.
        applyPendingViewportRestoreIfPossible()
        updateLifecycle()
        updateMinimap()
        callbacks.onViewportGeometryChanged(window)
    }

    /// Explicit pane lifecycle: panes within the visible rect (plus margin)
    /// render; everything else stops (Ghostty occlusion). Frames never change
    /// while offscreen, so re-entry never reflows.
    func updateLifecycle() {
        updateLifecycle(visibleRect: scrollView.contentView.documentVisibleRect)
    }

    func updateLifecycle(visibleRect visible: CGRect) {
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

    func setClipOrigin(_ origin: CGPoint, animated: Bool) {
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
