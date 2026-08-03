import AppKit
import Bonsplit
import Observation

@MainActor
final class RemoteTmuxMirrorPresentationContext {
    let mirror: RemoteTmuxWindowMirror
    var appearance: PanelAppearance
    var isOuterFocused: Bool
    var isVisibleInUI: Bool
    var portalPriority: Int
    var onOuterFocus: () -> Void
    var unreadSurfaceIDs: Set<UUID>

    init(
        mirror: RemoteTmuxWindowMirror,
        appearance: PanelAppearance,
        isOuterFocused: Bool,
        isVisibleInUI: Bool,
        portalPriority: Int,
        onOuterFocus: @escaping () -> Void,
        unreadSurfaceIDs: Set<UUID>
    ) {
        self.mirror = mirror
        self.appearance = appearance
        self.isOuterFocused = isOuterFocused
        self.isVisibleInUI = isVisibleInUI
        self.portalPriority = portalPriority
        self.onOuterFocus = onOuterFocus
        self.unreadSurfaceIDs = unreadSurfaceIDs
    }
}

@MainActor
final class RemoteTmuxWindowMirrorSplitViewController: NSViewController {
    private struct MirrorLayoutSnapshot {
        let structureVersion: Int
        let renderFrameSize: CGSize?
    }

    private let context: RemoteTmuxMirrorPresentationContext
    private let containerView = RemoteTmuxMirrorContainerView()
    private let bonsplitViewController: BonsplitViewController
    private var observationGeneration: UInt = 0
    private var lastStructureVersion: Int?

    init(
        mirror: RemoteTmuxWindowMirror,
        appearance: PanelAppearance,
        isOuterFocused: Bool,
        isVisibleInUI: Bool,
        portalPriority: Int,
        onOuterFocus: @escaping () -> Void,
        unreadSurfaceIDs: Set<UUID>
    ) {
        let context = RemoteTmuxMirrorPresentationContext(
            mirror: mirror,
            appearance: appearance,
            isOuterFocused: isOuterFocused,
            isVisibleInUI: isVisibleInUI,
            portalPriority: portalPriority,
            onOuterFocus: onOuterFocus,
            unreadSurfaceIDs: unreadSurfaceIDs
        )
        self.context = context
        self.bonsplitViewController = BonsplitViewController(
            controller: mirror.bonsplitController,
            content: { tab, paneID in
                RemoteTmuxTerminalContentController(context: context, tab: tab, paneID: paneID)
            },
            emptyPane: { _ in
                RemoteTmuxEmptyPaneViewController()
            }
        )
        super.init(nibName: nil, bundle: nil)
        applyVisibility(isVisibleInUI)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        addChild(bonsplitViewController)
        containerView.install(splitView: bonsplitViewController.view)
        containerView.mirror = context.mirror
        containerView.onContainerSizeChange = { [weak self] size, scale in
            self?.pushClientSize(pointSize: size, scale: scale)
        }
        view = containerView
        updateAppearanceAndFrame()
        observeLayout()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        applyVisibility(false)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyVisibility(context.isVisibleInUI)
    }

    func update(
        appearance: PanelAppearance,
        isOuterFocused: Bool,
        isVisibleInUI: Bool,
        portalPriority: Int,
        onOuterFocus: @escaping () -> Void,
        unreadSurfaceIDs: Set<UUID>
    ) {
        context.appearance = appearance
        context.isOuterFocused = isOuterFocused
        context.isVisibleInUI = isVisibleInUI
        context.portalPriority = portalPriority
        context.onOuterFocus = onOuterFocus
        context.unreadSurfaceIDs = unreadSurfaceIDs
        applyVisibility(isVisibleInUI)
        updateAppearanceAndFrame()
        bonsplitViewController.refreshContent()
        observeLayout()
    }

    func teardown() {
        observationGeneration &+= 1
        applyVisibility(false)
        containerView.onContainerSizeChange = nil
        if context.mirror.hostProbeView === containerView.probeView {
            context.mirror.hostProbeView = nil
        }
    }

    private func observeLayout() {
        observationGeneration &+= 1
        let generation = observationGeneration
        let snapshot = withObservationTracking {
            MirrorLayoutSnapshot(
                structureVersion: context.mirror.layoutStructureVersion,
                renderFrameSize: context.mirror.renderFrameSize
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                self.observeLayout()
            }
        }

        containerView.renderFrameSize = snapshot.renderFrameSize
        if lastStructureVersion != snapshot.structureVersion {
            lastStructureVersion = snapshot.structureVersion
            let scale = containerView.window?.backingScaleFactor
                ?? containerView.window?.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 1
            pushClientSize(pointSize: containerView.bounds.size, scale: scale)
        }
    }

    private func updateAppearanceAndFrame() {
        guard isViewLoaded else { return }
        containerView.backgroundColor = context.appearance.backgroundColor
        containerView.renderFrameSize = context.mirror.renderFrameSize
    }

    private func applyVisibility(_ visible: Bool) {
        context.mirror.isVisibleForSizing = visible
        context.mirror.bonsplitController.isInteractive = visible
        if visible {
            becameVisible()
        } else {
            context.mirror.cancelPendingControlPaneFocus()
            context.mirror.cancelPendingCreatedPaneFocus()
        }
    }

    private func pushClientSize(pointSize: CGSize, scale: CGFloat) {
        context.mirror.isVisibleForSizing = context.isVisibleInUI
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        context.mirror.noteContainerSize(pointSize: pointSize, scale: scale)
    }

    private func becameVisible() {
        guard isViewLoaded else {
            context.mirror.setNeedsSizingPassIgnoringInputs()
            return
        }
        let scale = containerView.window?.backingScaleFactor
            ?? containerView.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        pushClientSize(pointSize: containerView.bounds.size, scale: scale)
        context.mirror.setNeedsSizingPassIgnoringInputs()
    }
}

@MainActor
private final class RemoteTmuxTerminalContentController: NSViewController,
    BonsplitContentUpdating,
    BonsplitPaneDropZoneReceiving
{
    private let context: RemoteTmuxMirrorPresentationContext
    private let containerView = NSView()
    private var tab: Bonsplit.Tab
    private var paneID: PaneID
    private var dropZone: DropZone?
    private var panelController: PanelContentViewController?

    init(context: RemoteTmuxMirrorPresentationContext, tab: Bonsplit.Tab, paneID: PaneID) {
        self.context = context
        self.tab = tab
        self.paneID = paneID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        containerView.wantsLayer = true
        let click = NSClickGestureRecognizer(target: self, action: #selector(focusPane(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        containerView.addGestureRecognizer(click)
        view = containerView
        render()
    }

    func updateBonsplitContent(tab: Bonsplit.Tab, pane: PaneID) {
        self.tab = tab
        self.paneID = pane
        render()
    }

    func bonsplitPaneDropZoneDidChange(_ zone: DropZone?) {
        dropZone = zone
        render()
    }

    private func render() {
        guard isViewLoaded,
              let tmuxPaneID = context.mirror.tmuxPaneId(forTab: tab.id),
              let panel = context.mirror.panel(forPane: tmuxPaneID)
        else {
            removePanelController()
            containerView.layer?.backgroundColor = context.appearance.backgroundColor.cgColor
            return
        }
        containerView.layer?.backgroundColor = context.appearance.backgroundColor.cgColor
        let currentTabID = tab.id
        let currentPaneID = paneID
        let configuration = PanelContentConfiguration(
            panel: panel,
            workspaceID: panel.workspaceId,
            paneID: currentPaneID,
            isFocused: context.isOuterFocused && context.mirror.isFocused(tabId: currentTabID),
            isSelectedInPane: context.mirror.bonsplitController.selectedTab(inPane: currentPaneID)?.id == currentTabID,
            isVisibleInUI: context.isVisibleInUI,
            allowsPointerInput: context.isVisibleInUI,
            pointerEntryEventFilter: nil,
            portalPriority: context.portalPriority,
            isSplit: true,
            appearance: context.appearance,
            windowAppearance: nil,
            customSidebarTabManager: nil,
            customSidebarUnread: TerminalNotificationStore.shared.sidebarUnread,
            hasUnreadNotification: context.unreadSurfaceIDs.contains(panel.id),
            terminalAgentContext: "",
            paneOwnershipOverride: nil,
            terminalPaneOwnershipResolver: {
                context.mirror.bonsplitController.selectedTab(inPane: currentPaneID)?.id == currentTabID
            },
            paneDropZone: dropZone,
            onFocus: {
                context.onOuterFocus()
                context.mirror.setActivePane(tmuxPaneID, fromTmux: false)
            },
            onRequestPanelFocus: {
                context.onOuterFocus()
                context.mirror.setActivePane(tmuxPaneID, fromTmux: false)
            },
            onResumeAgentHibernation: {},
            onAutoResumeAgentHibernation: {},
            onTriggerFlash: {}
        )
        if let panelController {
            panelController.update(configuration: configuration)
            return
        }
        let controller = PanelContentViewController(configuration: configuration)
        panelController = controller
        addChild(controller)
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            child.topAnchor.constraint(equalTo: containerView.topAnchor),
            child.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    private func removePanelController() {
        guard let panelController else { return }
        panelController.teardown()
        panelController.view.removeFromSuperview()
        panelController.removeFromParent()
        self.panelController = nil
    }

    @objc private func focusPane(_ sender: NSClickGestureRecognizer) {
        context.onOuterFocus()
        context.mirror.bonsplitController.focusPane(paneID)
    }
}

@MainActor
final class RemoteTmuxMirrorContainerView: NSView {
    let probeView = MirrorHostProbeView()
    weak var mirror: RemoteTmuxWindowMirror? {
        didSet {
            probeView.mirror = mirror
            if window != nil { mirror?.hostProbeView = probeView }
        }
    }
    var backgroundColor: NSColor = .windowBackgroundColor {
        didSet { layer?.backgroundColor = backgroundColor.cgColor }
    }
    var renderFrameSize: CGSize? {
        didSet { needsLayout = true }
    }
    var onContainerSizeChange: ((CGSize, CGFloat) -> Void)?
    private weak var splitView: NSView?
    private var lastPublishedSize = CGSize.zero
    private var lastPublishedScale: CGFloat = 0

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        probeView.frame = bounds
        probeView.autoresizingMask = [.width, .height]
        addSubview(probeView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(splitView: NSView) {
        guard self.splitView !== splitView else { return }
        self.splitView?.removeFromSuperview()
        self.splitView = splitView
        addSubview(splitView, positioned: .above, relativeTo: probeView)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        probeView.frame = bounds
        splitView?.frame = NSRect(origin: .zero, size: renderFrameSize ?? bounds.size)
        publishContainerSizeIfChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            mirror?.hostProbeView = probeView
            publishContainerSizeIfChanged()
        } else if mirror?.hostProbeView === probeView {
            mirror?.hostProbeView = nil
        }
    }

    private func publishContainerSizeIfChanged() {
        let scale = window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? 1
        guard bounds.size != lastPublishedSize || scale != lastPublishedScale else { return }
        lastPublishedSize = bounds.size
        lastPublishedScale = scale
        onContainerSizeChange?(bounds.size, scale)
    }
}

/// A transparent view rooted at the mirror's real position. It supplies a
/// stable window handle for sizing diagnostics without intercepting input.
@MainActor
final class MirrorHostProbeView: NSView {
    weak var mirror: RemoteTmuxWindowMirror?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        mirror?.setNeedsSizingPass()
    }
}

@MainActor
private final class RemoteTmuxEmptyPaneViewController: NSViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        self.view = view
    }
}
