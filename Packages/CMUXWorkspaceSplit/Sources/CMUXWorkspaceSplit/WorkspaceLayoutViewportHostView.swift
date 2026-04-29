import AppKit

final class WorkspaceLayoutViewportCanvasView: NSView {
    let surfaceRegistry: any WorkspaceSurfaceRegistryProtocol
    let debugName: String
    var viewportHosts: [WorkspacePaneMountIdentity: WorkspaceLayoutSurfaceViewportHostView] = [:]

    init(surfaceRegistry: any WorkspaceSurfaceRegistryProtocol, debugName: String) {
        self.surfaceRegistry = surfaceRegistry
        self.debugName = debugName
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        viewports: [WorkspaceLayoutViewportSnapshot],
        presentation _: WorkspaceLayoutPresentationSnapshot,
        paneDropZones: [UUID: DropZone?]
    ) {
        let liveIdentities = Set(viewports.map(\.mountIdentity))

        for viewport in viewports {
            let host = viewportHost(for: viewport.mountIdentity)
            host.apply(
                snapshot: viewport,
                surfaceRegistry: surfaceRegistry,
                activeDropZone: paneDropZones[viewport.paneId.id] ?? nil
            )
            if host.superview !== self {
                addSubview(host)
            }
        }

        for (identity, host) in viewportHosts where !liveIdentities.contains(identity) {
            host.prepareForRemoval(surfaceRegistry: surfaceRegistry)
            viewportHosts.removeValue(forKey: identity)
        }
    }

    func clear(surfaceRegistry: any WorkspaceSurfaceRegistryProtocol) {
        for (_, host) in viewportHosts {
            host.prepareForRemoval(surfaceRegistry: surfaceRegistry)
        }
        viewportHosts.removeAll()
    }

    func viewportHost(
        for identity: WorkspacePaneMountIdentity
    ) -> WorkspaceLayoutSurfaceViewportHostView {
        if let existing = viewportHosts[identity] {
            return existing
        }
        let host = WorkspaceLayoutSurfaceViewportHostView(
            mountIdentity: identity,
            surfaceRegistry: surfaceRegistry,
            debugCanvasName: debugName
        )
        viewportHosts[identity] = host
        return host
    }

#if DEBUG
    var debugMountedIdentities: Set<WorkspacePaneMountIdentity> {
        Set(viewportHosts.keys)
    }
#endif
}

@MainActor
final class WorkspaceLayoutViewportRevealCoverView: NSView {
    let spinner = NSProgressIndicator(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.sizeToFit()
        addSubview(spinner)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        spinner.sizeToFit()
        spinner.frame = CGRect(
            x: round((bounds.width - spinner.frame.width) / 2),
            y: round((bounds.height - spinner.frame.height) / 2),
            width: spinner.frame.width,
            height: spinner.frame.height
        )
    }

    func setVisible(_ visible: Bool) {
        isHidden = !visible
        if visible {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}

@MainActor
final class WorkspaceLayoutSurfaceViewportHostView: NSView {
    let mountIdentity: WorkspacePaneMountIdentity
    let surfaceRegistry: any WorkspaceSurfaceRegistryProtocol
    let debugCanvasName: String
    let slotView = WorkspaceLayoutPaneContentSlotView(frame: .zero)
    let revealCoverView = WorkspaceLayoutViewportRevealCoverView(frame: .zero)
    var mountedContent: WorkspaceLayoutMountedTabEntry?
    var currentSnapshot: WorkspaceLayoutViewportSnapshot?
    var lastPresentationFacts: WorkspaceSurfacePresentationFacts?

    init(
        mountIdentity: WorkspacePaneMountIdentity,
        surfaceRegistry: any WorkspaceSurfaceRegistryProtocol,
        debugCanvasName: String
    ) {
        self.mountIdentity = mountIdentity
        self.surfaceRegistry = surfaceRegistry
        self.debugCanvasName = debugCanvasName
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        addSubview(slotView)
        addSubview(revealCoverView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        synchronizeSlotFrameToBounds()
        revealCoverView.frame = bounds
        refreshSurfacePresentation(reason: "layout", force: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshSurfacePresentation(reason: "windowMove", force: true)
    }

    func apply(
        snapshot: WorkspaceLayoutViewportSnapshot,
        surfaceRegistry: any WorkspaceSurfaceRegistryProtocol,
        activeDropZone: DropZone?
    ) {
        frame = snapshot.frame
        synchronizeSlotFrameToBounds()
        currentSnapshot = snapshot
        let nextMountedContent = WorkspaceLayoutMountedTabEntry(
            contentId: snapshot.contentId,
            content: snapshot.content,
            mountIdentity: mountIdentity
        )

        if let mountedContent,
           (mountedContent.contentId != nextMountedContent.contentId
               || mountedContent.mountIdentity != nextMountedContent.mountIdentity) {
            surfaceRegistry.unmountContent(
                mountedContent.content,
                contentId: mountedContent.contentId,
                from: slotView
            )
            self.mountedContent = nil
        }

        surfaceRegistry.mountContent(
            snapshot.content,
            contentId: snapshot.contentId,
            in: slotView,
            activeDropZone: activeDropZone,
            onPresentationChange: { [weak self] in
                self?.updateRevealState(reason: "presentationChange", force: true)
            }
        )
        mountedContent = nextMountedContent
        refreshSurfacePresentation(reason: "apply", force: true)
    }

    #if DEBUG
    var debugSlotBounds: CGRect {
        slotView.bounds
    }

    var debugRevealPhase: WorkspaceSurfaceRevealPhase? {
        lastPresentationFacts?.revealPhase
    }

    var debugShowsRevealCover: Bool {
        !revealCoverView.isHidden
    }
    #endif

    func prepareForRemoval(surfaceRegistry: any WorkspaceSurfaceRegistryProtocol) {
        if let mountedContent {
            surfaceRegistry.unmountContent(
                mountedContent.content,
                contentId: mountedContent.contentId,
                from: slotView
            )
        }
        currentSnapshot = nil
        lastPresentationFacts = nil
        mountedContent = nil
        revealCoverView.setVisible(false)
        removeFromSuperview()
    }

    func refreshSurfacePresentation(reason: String, force: Bool) {
        guard currentSnapshot != nil else { return }
        guard let mountedContent else { return }
        surfaceRegistry.reconcileViewportLifecycle(
            mountedContent.content,
            contentId: mountedContent.contentId,
            in: slotView,
            reason: "viewport.\(reason)"
        )
        updateRevealState(reason: reason, force: force)
    }

    func updateRevealState(reason: String, force: Bool) {
        guard let currentSnapshot else { return }
        let nextFacts = surfaceRegistry.presentationFacts(
            currentSnapshot.content,
            contentId: currentSnapshot.contentId
        )
        guard force || nextFacts != lastPresentationFacts else { return }
        lastPresentationFacts = nextFacts
        revealCoverView.setVisible(nextFacts.showsLoadingCover)
    }

    func synchronizeSlotFrameToBounds() {
        guard slotView.frame != bounds else { return }
        slotView.frame = bounds
    }
}
