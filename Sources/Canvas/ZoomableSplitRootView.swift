import AppKit
import Bonsplit
import CmuxCanvas
import CmuxCanvasUI
import QuartzCore
import SwiftUI

@MainActor
final class ZoomableSplitRootView: NSView, CanvasViewportControlling {
    private weak var workspace: Workspace?
    private var isWorkspaceInputActive: Bool
    private let scrollView = ZoomableSplitScrollView()
    private let documentView = ZoomableSplitDocumentView()
    private let hostingView: NSHostingView<AnyView>
    var layoutSize: CGSize = .zero
    var viewportMagnification: CGFloat = 1
    private var commandScrollEventRouter: CanvasCommandScrollEventRouter?
    private var panePointerFocusMonitor: Any?
    private var clipBoundsObserver: (any NSObjectProtocol)?
    private var scrollSettleObservers: [any NSObjectProtocol] = []
    private var overviewRestore: (magnification: CGFloat, origin: CGPoint)?

    private static let revealMargin: CGFloat = 24
    private static let minMagnificationFloor: CGFloat = 0.1
    private static let maxMagnificationCeiling: CGFloat = 2.0

    init(workspace: Workspace, isWorkspaceInputActive: Bool, content: AnyView) {
        self.workspace = workspace
        self.isWorkspaceInputActive = isWorkspaceInputActive
        self.hostingView = NSHostingView(rootView: content)
        super.init(frame: .zero)

        wantsLayer = true
        configureScrollView()
        configureDocumentView()
        installViewportObservers()
        workspace.zoomableSplitViewport = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(isWorkspaceInputActive: Bool, content: AnyView) {
        self.isWorkspaceInputActive = isWorkspaceInputActive
        hostingView.rootView = content
        refreshHostedContent()
        workspace?.zoomableSplitViewport = self
        updateCommandScrollMonitor()
        updatePanePointerFocusMonitor()
        updateDocumentSize()
        synchronizeViewportGeometry()
    }

    func teardown() {
        removeCommandScrollMonitor()
        removePanePointerFocusMonitor()
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
        clipBoundsObserver = nil
        scrollSettleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        scrollSettleObservers = []
        if workspace?.zoomableSplitViewport === self {
            workspace?.zoomableSplitViewport = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeCommandScrollMonitor()
            removePanePointerFocusMonitor()
        } else {
            updateCommandScrollMonitor()
            updatePanePointerFocusMonitor()
            synchronizeViewportGeometry()
        }
    }

    override func layout() {
        super.layout()
        updateDocumentSize()
        synchronizeViewportGeometry()
    }

    // MARK: CanvasViewportControlling

    func modelDidChangeExternally(animated: Bool) {
        _ = animated
        updateDocumentSize()
        synchronizeViewportGeometry()
    }

    func revealPane(_ panelId: UUID, animated: Bool) {
        guard let paneFrame = paneFrame(containing: panelId) else { return }
        let visible = scrollView.contentView.documentVisibleRect
        let origin = CanvasViewportMath().originToReveal(
            canvasRect(from: paneFrame),
            viewportOrigin: canvasPoint(from: visible.origin),
            viewportSize: canvasSize(from: visible.size),
            margin: Self.revealMargin
        )
        let target = CGPoint(x: CGFloat(origin.x) * viewportMagnification, y: CGFloat(origin.y) * viewportMagnification)
        guard target != visible.origin else { return }
        setClipOrigin(target, animated: animated)
    }

    func toggleOverview() {
        if let restore = overviewRestore {
            overviewRestore = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                viewportMagnification = restore.magnification
                refreshHostedContent()
                scrollView.contentView.animator().setBoundsOrigin(restore.origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            synchronizeViewportGeometry()
            return
        }

        let content = layoutRect
        guard content.width > 1, content.height > 1 else { return }
        overviewRestore = (viewportMagnification, scrollView.contentView.bounds.origin)
        let viewportSize = scrollView.contentSize
        let fit = CGFloat(CanvasViewportMath().magnificationToFit(
            canvasRect(from: layoutRect),
            in: canvasSize(from: viewportSize),
            padding: 0,
            range: Double(scrollView.minMagnification)...Double(scrollView.maxMagnification)
        ))
        let targetOrigin = CGPoint(x: content.midX * fit - viewportSize.width / 2, y: content.midY * fit - viewportSize.height / 2)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            viewportMagnification = fit
            refreshHostedContent()
            scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        synchronizeViewportGeometry()
    }

    func zoom(by factor: CGFloat) {
        overviewRestore = nil
        let target = clampedMagnification(viewportMagnification * factor)
        setMagnification(target)
    }

    func resetZoom() {
        overviewRestore = nil
        setMagnification(1.0)
    }

    func setViewport(center: CGPoint, magnification: CGFloat?) {
        overviewRestore = nil
        let targetMagnification = magnification.map(clampedMagnification) ?? viewportMagnification
        let viewportSize = scrollView.contentSize
        let scaledCenter = CGPoint(x: center.x * targetMagnification, y: center.y * targetMagnification)
        viewportMagnification = targetMagnification
        refreshHostedContent()
        setClipOrigin(CGPoint(x: scaledCenter.x - viewportSize.width / 2, y: scaledCenter.y - viewportSize.height / 2), animated: false)
    }

    var currentMagnification: CGFloat { viewportMagnification }

    var currentCenterInCanvas: CGPoint {
        let visible = scrollView.contentView.documentVisibleRect
        return CGPoint(x: visible.midX, y: visible.midY)
    }

    // MARK: Setup

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.usesPredominantAxisScrolling = false
        scrollView.allowsMagnification = false
        scrollView.minMagnification = Self.minMagnificationFloor
        scrollView.maxMagnification = Self.maxMagnificationCeiling
        scrollView.drawsBackground = false
        scrollView.shouldSuppressPlainDocumentScroll = { [weak documentView] event in
            guard let documentView else { return false }
            let documentPoint = documentView.convert(event.locationInWindow, from: nil)
            return documentView.bounds.contains(documentPoint)
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func configureDocumentView() {
        documentView.wantsLayer = true
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = []
        hostingView.sizingOptions = []
        documentView.addSubview(hostingView)
        syncHostedContentGeometry()
    }

    private func installViewportObservers() {
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.synchronizeViewportGeometry()
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
                    self?.synchronizeViewportSettled()
                }
            }
        }
    }

    private func updateCommandScrollMonitor() {
        guard window != nil, isWorkspaceInputActive else {
            removeCommandScrollMonitor()
            return
        }
        installCommandScrollMonitor()
    }

    private func installCommandScrollMonitor() {
        guard commandScrollEventRouter == nil else { return }
        let router = CanvasCommandScrollEventRouter(
            rootView: self,
            scrollView: scrollView,
            paneViewAtRootPoint: { [weak self] point in
                self?.paneView(atRootPoint: point)
            },
            handleMagnifyEvent: { [weak self] event in
                self?.zoomByMagnify(event)
                return true
            },
            handleMagnify: { [weak self] in
                self?.synchronizeViewportGeometry()
            },
            handleOptionScroll: { [weak self] event in
                self?.zoomByScroll(event)
            },
            handlePlainScrollInPane: {}
        )
        router.install()
        commandScrollEventRouter = router
    }

    private func removeCommandScrollMonitor() {
        commandScrollEventRouter?.remove()
        commandScrollEventRouter = nil
    }

    private func updatePanePointerFocusMonitor() {
        guard window != nil, isWorkspaceInputActive else {
            removePanePointerFocusMonitor()
            return
        }
        installPanePointerFocusMonitor()
    }

    private func installPanePointerFocusMonitor() {
        guard panePointerFocusMonitor == nil else { return }
        panePointerFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }

            _ = self.focusPaneForPointerDown(event, in: window)
            return event
        }
    }

    private func removePanePointerFocusMonitor() {
        if let panePointerFocusMonitor {
            NSEvent.removeMonitor(panePointerFocusMonitor)
        }
        panePointerFocusMonitor = nil
    }

    // MARK: Viewport Math

    private func updateDocumentSize() {
        let contentSize = scrollView.contentSize
        guard contentSize.width > 1, contentSize.height > 1 else { return }
        let nextLayoutSize = CGSize(width: contentSize.width, height: contentSize.height)
        if layoutSize != nextLayoutSize {
            layoutSize = nextLayoutSize
            refreshHostedContent()
        }
        let documentSize = scaledDocumentSize
        if documentView.frame.size != documentSize {
            documentView.setFrameSize(documentSize)
            syncHostedContentGeometry()
            let currentOrigin = scrollView.contentView.bounds.origin
            let nextOrigin = boundedOrigin(currentOrigin)
            if nextOrigin != currentOrigin {
                scrollView.contentView.setBoundsOrigin(nextOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        updateMagnificationBounds()
    }

    private func setMagnification(_ magnification: CGFloat) {
        guard magnification != viewportMagnification else { return }
        let center = currentCenterInCanvas
        setViewport(center: center, magnification: magnification)
    }

    private func zoom(by factor: CGFloat, towardWindowLocation windowLocation: CGPoint) {
        overviewRestore = nil
        let target = clampedMagnification(viewportMagnification * factor)
        guard target != viewportMagnification else { return }
        let layoutAnchor = documentView.convert(windowLocation, from: nil)
        let clipAnchor = scrollView.contentView.convert(windowLocation, from: nil)
        viewportMagnification = target
        refreshHostedContent()
        setClipOrigin(CGPoint(x: layoutAnchor.x * target - clipAnchor.x, y: layoutAnchor.y * target - clipAnchor.y), animated: false)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        synchronizeViewportSettled()
    }

    private func zoomByMagnify(_ event: NSEvent) {
        let factor = max(0.05, 1 + event.magnification)
        zoom(by: factor, towardWindowLocation: event.locationInWindow)
    }

    private func zoomByScroll(_ event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let delta = precise ? event.scrollingDeltaY : event.deltaY
        guard delta != 0 else { return }
        let sensitivity: CGFloat = precise ? 0.005 : 0.10
        zoom(by: 1 + delta * sensitivity, towardWindowLocation: event.locationInWindow)
    }

    private func setClipOrigin(_ origin: CGPoint, animated: Bool) {
        let bounded = boundedOrigin(origin)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(bounded)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(bounded)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        synchronizeViewportGeometry()
    }

    private func boundedOrigin(_ origin: CGPoint) -> CGPoint {
        let visible = scrollView.contentView.bounds
        let bounds = CGRect(origin: .zero, size: scaledDocumentSize)
        return CGPoint(
            x: min(max(origin.x, bounds.minX), max(bounds.maxX - visible.width, bounds.minX)),
            y: min(max(origin.y, bounds.minY), max(bounds.maxY - visible.height, bounds.minY))
        )
    }

    private func clampedMagnification(_ magnification: CGFloat) -> CGFloat {
        min(max(magnification, scrollView.minMagnification), scrollView.maxMagnification)
    }

    private func updateMagnificationBounds() {
        let fit = fittedMagnification()
        scrollView.maxMagnification = max(Self.maxMagnificationCeiling, fit)
        scrollView.minMagnification = fit
        guard viewportMagnification < fit else { return }

        viewportMagnification = fit
        refreshHostedContent()
        let origin = boundedOrigin(scrollView.contentView.bounds.origin)
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func fittedMagnification() -> CGFloat {
        let content = layoutRect
        let viewportSize = scrollView.contentSize
        guard content.width > 0, content.height > 0, viewportSize.width > 0, viewportSize.height > 0 else { return Self.minMagnificationFloor }
        // Furthest zoomed out is the exact packed-layout fit, so wheel zoom cannot create empty space.
        let fit = CGFloat(CanvasViewportMath().magnificationToFit(
            canvasRect(from: content),
            in: canvasSize(from: viewportSize),
            padding: 0,
            range: Double(Self.minMagnificationFloor)...Double.greatestFiniteMagnitude
        ))
        return max(Self.minMagnificationFloor, fit)
    }

    private func paneView(atRootPoint point: CGPoint) -> NSView? {
        let documentPoint = documentView.convert(point, from: self)
        return documentView.bounds.contains(documentPoint) ? hostingView : nil
    }

    @discardableResult
    private func focusPaneForPointerDown(_ event: NSEvent, in window: NSWindow) -> Bool {
        let rootPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(rootPoint), pointerHitTargetsDocumentContent(event, in: window) else { return false }
        let documentPoint = documentView.convert(rootPoint, from: self)
        return focusPane(atDocumentPoint: documentPoint)
    }

    private func pointerHitTargetsDocumentContent(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        let rootPoint = convert(event.locationInWindow, from: nil)
        let documentPoint = documentView.convert(rootPoint, from: self)
        if let workspace, Self.pointTargetsPaneChrome(atDocumentPoint: documentPoint, in: workspace.bonsplitController.layoutSnapshot()) { return false }
        guard !Self.containsSplitDivider(atWindowPoint: event.locationInWindow, in: documentView) else { return false }
        let contentPoint = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(contentPoint) else { return false }
        return hitView === documentView || hitView.isDescendant(of: documentView)
    }

    @discardableResult
    private func focusPane(atDocumentPoint point: CGPoint) -> Bool {
        guard let workspace,
              let panelId = Self.selectedPanelId(
                atDocumentPoint: point,
                in: workspace.bonsplitController.layoutSnapshot(),
                panelIdFromSurfaceId: { workspace.panelIdFromSurfaceId($0) }
              ) else {
            return false
        }

        AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
            workspaceId: workspace.id,
            panelId: panelId,
            in: window
        )
        workspace.focusPanel(panelId)
        synchronizeViewportGeometry()
        return true
    }

    private func paneFrame(containing panelId: UUID) -> CGRect? {
        guard let workspace else { return nil }
        let surfaceId = workspace.surfaceIdFromPanelId(panelId)
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        guard let pane = snapshot.panes.first(where: { pane in
            guard let surfaceId else { return false }
            return pane.tabIds.contains(surfaceId.uuid.uuidString)
        }) ?? focusedPane(in: snapshot) else {
            return nil
        }
        return CGRect(x: pane.frame.x - snapshot.containerFrame.x, y: pane.frame.y - snapshot.containerFrame.y, width: pane.frame.width, height: pane.frame.height)
    }

    private func refreshHostedContent() {
        let documentSize = scaledDocumentSize
        if documentView.frame.size != documentSize {
            documentView.setFrameSize(documentSize)
        }
        syncHostedContentGeometry()
    }

    private func syncHostedContentGeometry() {
        documentView.bounds = CGRect(origin: .zero, size: layoutSize)
        hostingView.frame = layoutRect
    }

    // MARK: Portal Synchronization

    private func synchronizeViewportGeometry() {
        guard let window else { return }
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
    }

    private func synchronizeViewportSettled() {
        synchronizeViewportGeometry()
    }
}
