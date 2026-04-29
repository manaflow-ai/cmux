import AppKit
import SwiftUI

@MainActor
struct WorkspaceLayoutNativeHost: NSViewRepresentable {
    let hostBridge: WorkspaceLayoutInteractionHandlers
    let renderSnapshot: WorkspaceLayoutRenderSnapshot
    let surfaceRegistry: any WorkspaceSurfaceRegistryProtocol

    init(
        hostBridge: WorkspaceLayoutInteractionHandlers,
        renderSnapshot: WorkspaceLayoutRenderSnapshot,
        surfaceRegistry: any WorkspaceSurfaceRegistryProtocol
    ) {
        self.hostBridge = hostBridge
        self.renderSnapshot = renderSnapshot
        self.surfaceRegistry = surfaceRegistry
    }

    func makeNSView(context: Context) -> WorkspaceLayoutRootHostView {
        let view = WorkspaceLayoutRootHostView(
            hostBridge: hostBridge,
            renderSnapshot: renderSnapshot,
            surfaceRegistry: surfaceRegistry
        )
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: WorkspaceLayoutRootHostView, context: Context) {
        nsView.update(
            hostBridge: hostBridge,
            renderSnapshot: renderSnapshot,
            surfaceRegistry: surfaceRegistry
        )
    }

    static func dismantleNSView(_ nsView: WorkspaceLayoutRootHostView, coordinator: ()) {
        nsView.prepareForRemoval()
    }
}

@MainActor
final class WorkspaceLayoutRootHostView: NSView {
    var hostBridge: WorkspaceLayoutInteractionHandlers
    var desiredRenderSnapshot: WorkspaceLayoutRenderSnapshot
    var displayedRenderSnapshot: WorkspaceLayoutRenderSnapshot
    let surfaceRegistry: any WorkspaceSurfaceRegistryProtocol
    var activeLocalTabDrag: WorkspaceLayoutLocalDragSnapshot?

    let viewportCanvas: WorkspaceLayoutViewportCanvasView
    var currentRootView: NSView?
    var paneHosts: [UUID: WorkspaceLayoutPaneHostView] = [:]
    var splitHosts: [UUID: WorkspaceLayoutNativeSplitView] = [:]
    var dropOverlayCoordinator = WorkspacePaneDropOverlayCoordinator()
    var renderedPaneIds: Set<UUID> = []
    var renderedSplitIds: Set<UUID> = []
    var lastContainerFrame: CGRect = .zero

    init(
        hostBridge: WorkspaceLayoutInteractionHandlers,
        renderSnapshot: WorkspaceLayoutRenderSnapshot,
        surfaceRegistry: any WorkspaceSurfaceRegistryProtocol
    ) {
        self.hostBridge = hostBridge
        desiredRenderSnapshot = renderSnapshot
        displayedRenderSnapshot = renderSnapshot
        self.surfaceRegistry = surfaceRegistry
        activeLocalTabDrag = renderSnapshot.presentation.localTabDrag
        viewportCanvas = WorkspaceLayoutViewportCanvasView(
            surfaceRegistry: surfaceRegistry,
            debugName: "live"
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(viewportCanvas)
        updateBackground()
        rebuildTree()
        applyViewportScene()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        hostBridge: WorkspaceLayoutInteractionHandlers,
        renderSnapshot: WorkspaceLayoutRenderSnapshot,
        surfaceRegistry: any WorkspaceSurfaceRegistryProtocol
    ) {
        self.hostBridge = hostBridge
        desiredRenderSnapshot = renderSnapshot
        syncLocalTabDragIfNeeded(from: renderSnapshot)
        isHidden = false
        refreshPresentation()
        syncContainerFrameIfNeeded(isDragging: false)
    }

    override func layout() {
        super.layout()
        viewportCanvas.frame = bounds
        currentRootView?.frame = bounds
        syncContainerFrameIfNeeded(isDragging: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
#if DEBUG
        startupLog(
            "startup.root.windowMove host=\(Unmanaged.passUnretained(self).toOpaque()) " +
                "inWindow=\(window != nil ? 1 : 0)"
        )
#endif
        refreshPresentation()
        syncContainerFrameIfNeeded(isDragging: false)
    }

    func prepareForRemoval() {
        clearLocalTabDrag(propagateToWorkspace: false)
        viewportCanvas.clear(surfaceRegistry: surfaceRegistry)

        for (_, host) in paneHosts {
            host.prepareForRemoval()
            if host.superview != nil {
                host.removeFromSuperview()
            }
        }
        paneHosts.removeAll()

        for (_, host) in splitHosts {
            host.removeAllChildren()
            if host.superview != nil {
                host.removeFromSuperview()
            }
        }
        splitHosts.removeAll()

        dropOverlayCoordinator.clearAll()
        renderedPaneIds.removeAll()
        renderedSplitIds.removeAll()

        currentRootView?.removeFromSuperview()
        currentRootView = nil
    }

    func updateBackground() {
        layer?.backgroundColor = TabBarColors.nsColorPaneBackground(
            for: displayedRenderSnapshot.presentation.appearance
        ).cgColor
    }

    func notifyGeometryChanged(isDragging: Bool) {
        syncContainerFrameIfNeeded(isDragging: isDragging)
        hostBridge.notifyGeometryChange(isDragging: isDragging)
    }

    func updatePaneDropZone(_ zone: DropZone, for paneId: PaneID) {
        guard dropOverlayCoordinator.setZone(zone, for: paneId) else { return }
        syncPaneDropState(for: paneId)
    }

    func clearPaneDropZone(for paneId: PaneID) {
        guard dropOverlayCoordinator.clearZone(for: paneId) else { return }
        syncPaneDropState(for: paneId)
    }

    func clearPaneDropZoneImmediately(for paneId: PaneID) {
        guard dropOverlayCoordinator.clearZoneImmediately(for: paneId) else { return }
        syncPaneDropState(for: paneId)
    }

    func completePaneDropOverlayHide(for paneId: PaneID, generation: UInt64) {
        guard dropOverlayCoordinator.completeHide(for: paneId, generation: generation) else { return }
        syncPaneDropState(for: paneId)
    }

    func syncContainerFrameIfNeeded(isDragging: Bool) {
        let frame = convert(bounds, to: nil)
        guard frame != lastContainerFrame else { return }
        lastContainerFrame = frame
        hostBridge.setContainerFrame(frame)
        if !isDragging {
            hostBridge.notifyGeometryChange(isDragging: false)
        }
    }

    func rebuildTree() {
        let nextPaneIds = displayedRenderSnapshot.root.paneIds
        let nextSplitIds = displayedRenderSnapshot.root.splitIds

        let nextRootView = hostView(for: displayedRenderSnapshot.root)

        if currentRootView !== nextRootView {
            if nextRootView.superview !== self {
                addSubview(nextRootView)
            }
            if currentRootView?.superview === self {
                currentRootView?.removeFromSuperview()
            }
            currentRootView = nextRootView
        }

        currentRootView?.frame = bounds
        renderedPaneIds = nextPaneIds
        renderedSplitIds = nextSplitIds
        cleanupUnusedHosts()
    }

    func applyViewportScene() {
        viewportCanvas.update(
            viewports: displayedRenderSnapshot.viewports,
            presentation: displayedRenderSnapshot.presentation,
            paneDropZones: dropOverlayCoordinator.viewportDropZones()
        )
    }

    func cleanupUnusedHosts() {
        let livePaneIds = displayedRenderSnapshot.root.paneIds
        let liveSplitIds = displayedRenderSnapshot.root.splitIds

        for (id, host) in paneHosts where !livePaneIds.contains(id) {
            host.prepareForRemoval()
            dropOverlayCoordinator.removePane(PaneID(id: id))
            if host.superview != nil {
                host.removeFromSuperview()
            }
            paneHosts.removeValue(forKey: id)
        }

        for (id, host) in splitHosts where !liveSplitIds.contains(id) {
            host.removeAllChildren()
            if host.superview != nil {
                host.removeFromSuperview()
            }
            splitHosts.removeValue(forKey: id)
        }
    }

    func hostView(for node: WorkspaceLayoutRenderNodeSnapshot) -> NSView {
        switch node {
        case .pane(let snapshot):
            return paneHost(for: snapshot)
        case .split(let snapshot):
            return splitHost(for: snapshot)
        }
    }

    func paneHost(for snapshot: WorkspaceLayoutPaneRenderSnapshot) -> WorkspaceLayoutPaneHostView {
        let subviewHostBridge = interactionHandlersForSubviews()
        if let existing = paneHosts[snapshot.paneId.id] {
            existing.update(
                snapshot: snapshot,
                hostBridge: subviewHostBridge,
                presentation: displayedRenderSnapshot.presentation,
                localTabDrag: activeLocalTabDrag,
                overlayPresentation: dropOverlayCoordinator.overlayPresentation(for: snapshot.paneId),
                contentDropZone: dropOverlayCoordinator.activeDropZone(for: snapshot.paneId),
                surfaceRegistry: surfaceRegistry
            )
            return existing
        }

        let host = WorkspaceLayoutPaneHostView(
            rootHost: self,
            snapshot: snapshot,
            hostBridge: subviewHostBridge,
            presentation: displayedRenderSnapshot.presentation,
            localTabDrag: activeLocalTabDrag,
            overlayPresentation: dropOverlayCoordinator.overlayPresentation(for: snapshot.paneId),
            contentDropZone: dropOverlayCoordinator.activeDropZone(for: snapshot.paneId),
            surfaceRegistry: surfaceRegistry
        )
        paneHosts[snapshot.paneId.id] = host
        return host
    }

    func splitHost(for snapshot: WorkspaceLayoutSplitRenderSnapshot) -> WorkspaceLayoutNativeSplitView {
        if let existing = splitHosts[snapshot.splitId] {
            existing.update(
                snapshot: snapshot,
                hostBridge: hostBridge,
                rootHost: self,
                firstChild: hostView(for: snapshot.first),
                secondChild: hostView(for: snapshot.second),
                appearance: displayedRenderSnapshot.presentation.appearance
            )
            return existing
        }

        let host = WorkspaceLayoutNativeSplitView(
            snapshot: snapshot,
            hostBridge: hostBridge,
            rootHost: self,
            firstChild: hostView(for: snapshot.first),
            secondChild: hostView(for: snapshot.second),
            appearance: displayedRenderSnapshot.presentation.appearance
        )
        splitHosts[snapshot.splitId] = host
        return host
    }

    func isCurrentSplitHost(_ host: WorkspaceLayoutNativeSplitView, for splitId: UUID) -> Bool {
        splitHosts[splitId] === host
    }

    func refreshPresentation() {
        displayedRenderSnapshot = desiredRenderSnapshot
        updateBackground()
        rebuildTree()
        applyViewportScene()
    }

    func syncLocalTabDragIfNeeded(from renderSnapshot: WorkspaceLayoutRenderSnapshot) {
        guard let snapshotLocalTabDrag = renderSnapshot.presentation.localTabDrag else {
            guard activeLocalTabDrag != nil else { return }
            clearLocalTabDrag(propagateToWorkspace: false)
            return
        }
        guard snapshotLocalTabDrag != activeLocalTabDrag else { return }
        activeLocalTabDrag = snapshotLocalTabDrag
        propagateLocalTabDrag()
    }

    func interactionHandlersForSubviews() -> WorkspaceLayoutInteractionHandlers {
        WorkspaceLayoutInteractionHandlers(
            notifyGeometryChangeHandler: { [weak self] isDragging in
                self?.hostBridge.notifyGeometryChange(isDragging: isDragging)
            },
            setContainerFrameHandler: { [weak self] frame in
                self?.hostBridge.setContainerFrame(frame)
            },
            setDividerPositionHandler: { [weak self] position, splitId in
                self?.hostBridge.setDividerPosition(position, forSplit: splitId) ?? false
            },
            consumeSplitEntryAnimationHandler: { [weak self] splitId in
                self?.hostBridge.consumeSplitEntryAnimation(splitId)
            },
            beginTabDragHandler: { [weak self] tabId, sourcePaneId in
                self?.beginLocalTabDrag(tabId: tabId, sourcePaneId: sourcePaneId)
            },
            clearDragStateHandler: { [weak self] in
                self?.clearLocalTabDrag()
            },
            focusPaneHandler: { [weak self] paneId in
                self?.hostBridge.focusPane(paneId) ?? false
            },
            selectTabHandler: { [weak self] tabId in
                self?.hostBridge.selectTab(tabId)
            },
            requestCloseTabHandler: { [weak self] tabId, paneId in
                self?.hostBridge.requestCloseTab(tabId, inPane: paneId) ?? false
            },
            togglePaneZoomHandler: { [weak self] paneId in
                self?.hostBridge.togglePaneZoom(inPane: paneId) ?? false
            },
            requestTabContextActionHandler: { [weak self] action, tabId, paneId in
                self?.hostBridge.requestTabContextAction(action, for: tabId, inPane: paneId)
            },
            requestNewTabHandler: { [weak self] kind, paneId in
                self?.hostBridge.requestNewTab(kind: kind, inPane: paneId)
            },
            splitPaneHandler: { [weak self] paneId, orientation in
                self?.hostBridge.splitPane(paneId, orientation: orientation)
            },
            splitPaneMovingTabHandler: { [weak self] paneId, orientation, tabId, insertFirst, focusNewPane in
                self?.hostBridge.splitPane(
                    paneId,
                    orientation: orientation,
                    movingTab: tabId,
                    insertFirst: insertFirst,
                    focusNewPane: focusNewPane
                )
            },
            moveTabHandler: { [weak self] tabId, paneId, index in
                self?.hostBridge.moveTab(tabId, toPane: paneId, atIndex: index) ?? false
            },
            handleExternalTabDropHandler: { [weak self] request in
                self?.hostBridge.handleExternalTabDrop(request) ?? false
            },
            handleFileDropHandler: { [weak self] urls, paneId in
                self?.hostBridge.handleFileDrop(urls, in: paneId) ?? false
            }
        )
    }

    func beginLocalTabDrag(tabId: TabID, sourcePaneId: PaneID) {
        let drag = WorkspaceLayoutLocalDragSnapshot(tabId: tabId, sourcePaneId: sourcePaneId)
        guard activeLocalTabDrag != drag else { return }
        activeLocalTabDrag = drag
        propagateLocalTabDrag()
        hostBridge.beginTabDrag(tabId: tabId, sourcePaneId: sourcePaneId)
    }

    func clearLocalTabDrag(propagateToWorkspace: Bool = true) {
        let hadActiveLocalTabDrag = activeLocalTabDrag != nil
        activeLocalTabDrag = nil
        if hadActiveLocalTabDrag {
            propagateLocalTabDrag()
            clearAllPaneDropOverlays()
        }
        if propagateToWorkspace {
            hostBridge.clearDragState()
        }
    }

    func propagateLocalTabDrag() {
        for host in paneHosts.values {
            host.updateLocalTabDrag(activeLocalTabDrag)
        }
    }

    func clearAllPaneDropOverlays() {
        let paneIds = Array(paneHosts.keys).map(PaneID.init(id:))
        var didChange = false
        for paneId in paneIds {
            didChange = dropOverlayCoordinator.clearZone(for: paneId) || didChange
            paneHosts[paneId.id]?.updateDropPresentation(
                overlayPresentation: dropOverlayCoordinator.overlayPresentation(for: paneId),
                contentDropZone: dropOverlayCoordinator.activeDropZone(for: paneId),
                surfaceRegistry: surfaceRegistry
            )
        }
        if didChange {
            viewportCanvas.update(
                viewports: displayedRenderSnapshot.viewports,
                presentation: displayedRenderSnapshot.presentation,
                paneDropZones: dropOverlayCoordinator.viewportDropZones()
            )
        }
    }

    func syncPaneDropState(for paneId: PaneID) {
        paneHosts[paneId.id]?.updateDropPresentation(
            overlayPresentation: dropOverlayCoordinator.overlayPresentation(for: paneId),
            contentDropZone: dropOverlayCoordinator.activeDropZone(for: paneId),
            surfaceRegistry: surfaceRegistry
        )
        viewportCanvas.update(
            viewports: displayedRenderSnapshot.viewports,
            presentation: displayedRenderSnapshot.presentation,
            paneDropZones: dropOverlayCoordinator.viewportDropZones()
        )
    }

#if DEBUG
    var debugViewportMountIdentities: Set<WorkspacePaneMountIdentity> {
        viewportCanvas.debugMountedIdentities
    }

    func debugPaneMountedDirectContentIdentity(_ paneId: PaneID) -> WorkspacePaneMountIdentity? {
        paneHosts[paneId.id]?.debugMountedDirectContentIdentity
    }

    func debugPaneDirectContentBounds(_ paneId: PaneID) -> CGRect {
        paneHosts[paneId.id]?.debugDirectContentBounds ?? .zero
    }

    func debugPaneUsesDirectTerminalHost(_ paneId: PaneID) -> Bool {
        paneHosts[paneId.id]?.debugUsesDirectTerminalHost ?? false
    }

    func debugPaneLocalTabDrag(_ paneId: PaneID) -> WorkspaceLayoutLocalDragSnapshot? {
        paneHosts[paneId.id]?.debugLocalTabDrag
    }

    func debugBeginLocalTabDrag(tabId: TabID, sourcePaneId: PaneID) {
        beginLocalTabDrag(tabId: tabId, sourcePaneId: sourcePaneId)
    }

    func debugClearLocalTabDrag() {
        clearLocalTabDrag()
    }
#endif
}

func workspaceLayoutRemoveSubviewIfOwned(_ child: NSView?, from container: NSView) {
    guard let child,
          child.superview === container else { return }
    child.removeFromSuperview()
}
