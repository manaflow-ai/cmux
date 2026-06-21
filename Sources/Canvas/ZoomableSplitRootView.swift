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
    private let scrollView = NSScrollView()
    private let documentView = ZoomableSplitDocumentView()
    private let hostingView: NSHostingView<AnyView>
    private var commandScrollEventRouter: CanvasCommandScrollEventRouter?
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
    required init?(coder: NSCoder) {
        nil
    }

    func update(isWorkspaceInputActive: Bool, content: AnyView) {
        self.isWorkspaceInputActive = isWorkspaceInputActive
        hostingView.rootView = content
        workspace?.zoomableSplitViewport = self
        updateCommandScrollMonitor()
        updateDocumentSize()
        synchronizeViewportGeometry()
    }

    func teardown() {
        removeCommandScrollMonitor()
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
        } else {
            updateCommandScrollMonitor()
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
        let target = cgPoint(from: origin)
        guard target != visible.origin else { return }
        setClipOrigin(target, animated: animated)
    }

    func toggleOverview() {
        if let restore = overviewRestore {
            overviewRestore = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                scrollView.animator().magnification = restore.magnification
                scrollView.contentView.animator().setBoundsOrigin(restore.origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            synchronizeViewportGeometry()
            return
        }

        let content = documentView.bounds
        guard content.width > 1, content.height > 1 else { return }
        overviewRestore = (scrollView.magnification, scrollView.contentView.bounds.origin)
        let viewportSize = scrollView.contentSize
        let fit = CGFloat(CanvasViewportMath().magnificationToFit(
            canvasRect(from: content),
            in: canvasSize(from: viewportSize),
            padding: 0,
            range: Double(scrollView.minMagnification)...Double(scrollView.maxMagnification)
        ))
        let clipSize = CGSize(width: viewportSize.width / fit, height: viewportSize.height / fit)
        let targetOrigin = CGPoint(
            x: content.midX - clipSize.width / 2,
            y: content.midY - clipSize.height / 2
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            scrollView.animator().magnification = fit
            scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        synchronizeViewportGeometry()
    }

    func zoom(by factor: CGFloat) {
        overviewRestore = nil
        let target = clampedMagnification(scrollView.magnification * factor)
        setMagnification(target)
    }

    func resetZoom() {
        overviewRestore = nil
        setMagnification(1.0)
    }

    func setViewport(center: CGPoint, magnification: CGFloat?) {
        overviewRestore = nil
        let targetMagnification = magnification.map(clampedMagnification) ?? scrollView.magnification
        let viewportSize = scrollView.contentSize
        let clipSize = CGSize(
            width: viewportSize.width / targetMagnification,
            height: viewportSize.height / targetMagnification
        )
        scrollView.magnification = targetMagnification
        setClipOrigin(
            CGPoint(x: center.x - clipSize.width / 2, y: center.y - clipSize.height / 2),
            animated: false
        )
    }

    var currentMagnification: CGFloat {
        scrollView.magnification
    }

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
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.minMagnificationFloor
        scrollView.maxMagnification = Self.maxMagnificationCeiling
        scrollView.drawsBackground = false
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
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.sizingOptions = []
        documentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: documentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
        ])
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

    // MARK: Viewport Math

    private func updateDocumentSize() {
        let contentSize = scrollView.contentSize
        guard contentSize.width > 1, contentSize.height > 1 else { return }
        let documentSize = CGSize(width: contentSize.width, height: contentSize.height)
        if documentView.frame.size != documentSize {
            documentView.setFrameSize(documentSize)
            hostingView.frame = documentView.bounds
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
        guard magnification != scrollView.magnification else { return }
        let center = currentCenterInCanvas
        setViewport(center: center, magnification: magnification)
    }

    private func zoom(by factor: CGFloat, towardWindowLocation windowLocation: CGPoint) {
        overviewRestore = nil
        let target = clampedMagnification(scrollView.magnification * factor)
        guard target != scrollView.magnification else { return }
        let anchor = scrollView.contentView.convert(windowLocation, from: nil)
        scrollView.setMagnification(target, centeredAt: anchor)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        synchronizeViewportSettled()
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
        let visible = scrollView.contentView.documentVisibleRect
        let bounds = documentView.bounds
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
        let maximum = max(Self.maxMagnificationCeiling, fit)
        scrollView.maxMagnification = maximum
        scrollView.minMagnification = fit
        guard scrollView.magnification < fit else { return }

        scrollView.magnification = fit
        let origin = boundedOrigin(scrollView.contentView.bounds.origin)
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func fittedMagnification() -> CGFloat {
        let content = documentView.bounds
        let viewportSize = scrollView.contentSize
        guard content.width > 0, content.height > 0, viewportSize.width > 0, viewportSize.height > 0 else {
            return Self.minMagnificationFloor
        }
        // Zoomable splits are not a free canvas: the furthest zoomed-out state
        // is the exact packed-layout fit, so wheel zoom cannot create empty space.
        let fit = CGFloat(CanvasViewportMath().magnificationToFit(
            canvasRect(from: content),
            in: canvasSize(from: viewportSize),
            padding: 0,
            range: Double(Self.minMagnificationFloor)...Double.greatestFiniteMagnitude
        ))
        return max(Self.minMagnificationFloor, fit)
    }

    private func canvasRect(from rect: CGRect) -> CanvasRect {
        CanvasRect(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    private func canvasPoint(from point: CGPoint) -> CanvasPoint {
        CanvasPoint(x: Double(point.x), y: Double(point.y))
    }

    private func canvasSize(from size: CGSize) -> CanvasSize {
        CanvasSize(width: Double(size.width), height: Double(size.height))
    }

    private func cgPoint(from point: CanvasPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    private func paneView(atRootPoint point: CGPoint) -> NSView? {
        let documentPoint = documentView.convert(point, from: self)
        return documentView.bounds.contains(documentPoint) ? hostingView : nil
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
        return CGRect(
            x: pane.frame.x - snapshot.containerFrame.x,
            y: pane.frame.y - snapshot.containerFrame.y,
            width: pane.frame.width,
            height: pane.frame.height
        )
    }

    private func focusedPane(in snapshot: LayoutSnapshot) -> PaneGeometry? {
        guard let focusedPaneId = snapshot.focusedPaneId else { return nil }
        return snapshot.panes.first { $0.paneId == focusedPaneId }
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
