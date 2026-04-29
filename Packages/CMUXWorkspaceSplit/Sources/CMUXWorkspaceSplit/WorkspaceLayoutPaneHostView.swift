import AppKit
import SwiftUI

@MainActor
final class WorkspaceLayoutPaneHostView: NSView {
    weak var rootHost: WorkspaceLayoutRootHostView?
    var snapshot: WorkspaceLayoutPaneRenderSnapshot
    let hostBridge: WorkspaceLayoutInteractionHandlers
    var presentation: WorkspaceLayoutPresentationSnapshot
    var localTabDrag: WorkspaceLayoutLocalDragSnapshot?
    let surfaceRegistry: any WorkspaceSurfaceRegistryProtocol

    let directContentSlotView = WorkspaceLayoutPaneContentSlotView(frame: .zero)
    let tabBarView = WorkspaceLayoutNativeTabBarView(frame: .zero)
    let dropOverlayView = WorkspaceLayoutPaneDropOverlayView(frame: .zero)
    var overlayPresentation: WorkspacePaneDropOverlayPresentation = .hidden
    var contentDropZone: DropZone? = nil
    var mountedDirectContent: WorkspaceLayoutMountedTabEntry?

    init(
        rootHost: WorkspaceLayoutRootHostView,
        snapshot: WorkspaceLayoutPaneRenderSnapshot,
        hostBridge: WorkspaceLayoutInteractionHandlers,
        presentation: WorkspaceLayoutPresentationSnapshot,
        localTabDrag: WorkspaceLayoutLocalDragSnapshot?,
        overlayPresentation: WorkspacePaneDropOverlayPresentation,
        contentDropZone: DropZone?,
        surfaceRegistry: any WorkspaceSurfaceRegistryProtocol
    ) {
        self.rootHost = rootHost
        self.snapshot = snapshot
        self.hostBridge = hostBridge
        self.presentation = presentation
        self.localTabDrag = localTabDrag
        self.overlayPresentation = overlayPresentation
        self.contentDropZone = contentDropZone
        self.surfaceRegistry = surfaceRegistry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        directContentSlotView.isHidden = true
        addSubview(directContentSlotView)
        addSubview(tabBarView)
        addSubview(dropOverlayView)
        dropOverlayView.hitTestPassthroughEnabled = true
        update(
            snapshot: snapshot,
            hostBridge: hostBridge,
            presentation: presentation,
            localTabDrag: localTabDrag,
            overlayPresentation: overlayPresentation,
            contentDropZone: contentDropZone,
            surfaceRegistry: surfaceRegistry
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        snapshot: WorkspaceLayoutPaneRenderSnapshot,
        hostBridge: WorkspaceLayoutInteractionHandlers,
        presentation: WorkspaceLayoutPresentationSnapshot,
        localTabDrag: WorkspaceLayoutLocalDragSnapshot?,
        overlayPresentation: WorkspacePaneDropOverlayPresentation,
        contentDropZone: DropZone?,
        surfaceRegistry: any WorkspaceSurfaceRegistryProtocol
    ) {
        self.snapshot = snapshot
        self.presentation = presentation
        self.localTabDrag = localTabDrag
        self.overlayPresentation = overlayPresentation
        self.contentDropZone = contentDropZone

        tabBarView.update(
            snapshot: snapshot.chrome,
            hostBridge: hostBridge,
            presentation: presentation,
            localTabDrag: localTabDrag
        )
        tabBarView.onTabMutation = { [weak self] in
            self?.rootHost?.notifyGeometryChanged(isDragging: false)
        }

        dropOverlayView.update(
            paneId: snapshot.paneId,
            hostBridge: hostBridge,
            presentation: presentation,
            localTabDrag: localTabDrag,
            overlayPresentation: overlayPresentation,
            onZoneUpdated: { [weak self] zone in
                self?.rootHost?.updatePaneDropZone(zone, for: snapshot.paneId)
            },
            onZoneCleared: { [weak self] in
                self?.rootHost?.clearPaneDropZone(for: snapshot.paneId)
            },
            onDropSucceeded: { [weak self] in
                self?.rootHost?.clearPaneDropZoneImmediately(for: snapshot.paneId)
            },
            onHideAnimationCompleted: { [weak self] generation in
                self?.rootHost?.completePaneDropOverlayHide(for: snapshot.paneId, generation: generation)
            },
            onDropPerformed: { [weak self] in
                self?.rootHost?.notifyGeometryChanged(isDragging: false)
            }
        )
        refreshDirectContentMount(surfaceRegistry: surfaceRegistry, reconcileLifecycle: true)
        needsLayout = true
    }

    func updateLocalTabDrag(_ localTabDrag: WorkspaceLayoutLocalDragSnapshot?) {
        guard self.localTabDrag != localTabDrag else { return }
        self.localTabDrag = localTabDrag
        tabBarView.updateLocalTabDrag(localTabDrag)
        dropOverlayView.updateLocalTabDrag(localTabDrag)
    }

    func prepareForRemoval() {
        clearDirectContent(surfaceRegistry: surfaceRegistry)
    }

    override func layout() {
        super.layout()
        let barHeight = presentation.appearance.tabBarHeight
        let topInset = min(barHeight, max(0, bounds.height - 1))
        let contentHeight = max(0, bounds.height - topInset)
        directContentSlotView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        tabBarView.frame = CGRect(x: 0, y: contentHeight, width: bounds.width, height: topInset)
        dropOverlayView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        reconcileDirectContentLifecycle(reason: "layout")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileDirectContentLifecycle(reason: "windowMove")
    }

    func updateDropPresentation(
        overlayPresentation: WorkspacePaneDropOverlayPresentation,
        contentDropZone: DropZone?,
        surfaceRegistry: any WorkspaceSurfaceRegistryProtocol
    ) {
        let didChangeOverlay = self.overlayPresentation != overlayPresentation
        let didChangeContentDropZone = self.contentDropZone != contentDropZone
        self.overlayPresentation = overlayPresentation
        self.contentDropZone = contentDropZone
        if didChangeOverlay {
            dropOverlayView.updateOverlayPresentation(overlayPresentation)
        }
        if didChangeContentDropZone && !snapshot.content.usesDirectPaneHost {
            refreshDirectContentMount(surfaceRegistry: surfaceRegistry, reconcileLifecycle: false)
        }
    }

    func refreshDirectContentMount(
        surfaceRegistry: any WorkspaceSurfaceRegistryProtocol,
        reconcileLifecycle: Bool
    ) {
        guard snapshot.content.usesDirectPaneHost else {
            clearDirectContent(surfaceRegistry: surfaceRegistry)
            return
        }

        let nextMountedContent = WorkspaceLayoutMountedTabEntry(
            contentId: snapshot.contentId,
            content: snapshot.content,
            mountIdentity: snapshot.content.mountIdentity(contentId: snapshot.contentId)
        )

        if let mountedDirectContent,
           (mountedDirectContent.contentId != nextMountedContent.contentId
               || mountedDirectContent.mountIdentity != nextMountedContent.mountIdentity) {
            surfaceRegistry.unmountContent(
                mountedDirectContent.content,
                contentId: mountedDirectContent.contentId,
                from: directContentSlotView
            )
            self.mountedDirectContent = nil
        }

        let effectiveContentDropZone = snapshot.content.usesDirectPaneHost ? nil : self.contentDropZone
        surfaceRegistry.mountContent(
            snapshot.content,
            contentId: snapshot.contentId,
            in: directContentSlotView,
            activeDropZone: effectiveContentDropZone,
            onPresentationChange: nil
        )
        mountedDirectContent = nextMountedContent
        directContentSlotView.isHidden = false
        if reconcileLifecycle {
            reconcileDirectContentLifecycle(reason: "update")
        }
    }

    func reconcileDirectContentLifecycle(reason: String) {
        guard let mountedDirectContent else { return }
        surfaceRegistry.reconcileViewportLifecycle(
            mountedDirectContent.content,
            contentId: mountedDirectContent.contentId,
            in: directContentSlotView,
            reason: "pane.\(reason)"
        )
    }

    func clearDirectContent(surfaceRegistry: any WorkspaceSurfaceRegistryProtocol) {
        if let mountedDirectContent {
            surfaceRegistry.unmountContent(
                mountedDirectContent.content,
                contentId: mountedDirectContent.contentId,
                from: directContentSlotView
            )
        }
        mountedDirectContent = nil
        directContentSlotView.clearContentView()
        directContentSlotView.isHidden = true
    }

#if DEBUG
    var debugMountedDirectContentIdentity: WorkspacePaneMountIdentity? {
        mountedDirectContent?.mountIdentity
    }

    var debugDirectContentBounds: CGRect {
        directContentSlotView.bounds
    }

    var debugUsesDirectTerminalHost: Bool {
        if case .terminal = mountedDirectContent?.content {
            return true
        }
        return false
    }

    var debugLocalTabDrag: WorkspaceLayoutLocalDragSnapshot? {
        localTabDrag
    }
#endif
}

@MainActor
final class WorkspaceLayoutPaneContentSlotView: NSView {
    var installedContentView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installContentView(_ view: NSView) {
        if installedContentView !== view {
            if let previous = installedContentView, previous.superview === self {
                previous.removeFromSuperview()
            }
            if view.superview !== self {
                view.removeFromSuperview()
                addSubview(view)
            }
            installedContentView = view
        } else if view.superview !== self {
            view.removeFromSuperview()
            addSubview(view)
        }

        view.frame = bounds
        view.autoresizingMask = [.width, .height]
    }

    func clearContentView() {
        if let installedContentView, installedContentView.superview === self {
            installedContentView.removeFromSuperview()
        }
        installedContentView = nil
    }

    override func layout() {
        super.layout()
        guard let installedContentView else { return }
        guard installedContentView.superview === self else {
            self.installedContentView = nil
            return
        }
        installedContentView.frame = bounds
    }
}
