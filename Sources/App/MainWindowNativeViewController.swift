import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxExtensionSidebarExamples
import CmuxFeedback
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarProviderKit
import CmuxSidebarRemoteRender
import CmuxUpdater
import CmuxWorkspaces
import Combine

@MainActor
private final class MainWindowNativeRootLayoutView: NSView {
    weak var owner: MainWindowNativeViewController?

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        owner?.rootViewDidMoveToWindow(window)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.effectiveAppearanceDidChange()
    }
}

@MainActor
private final class MainWindowNativeSidebarResizeHandle: NSView {
    enum Edge {
        case leftSidebarTrailing
        case rightSidebarLeading
    }

    private let edge: Edge
    private let currentWidth: () -> CGFloat
    private let clampWidth: (CGFloat) -> CGFloat
    private let applyWidth: (CGFloat) -> Void
    private let didBegin: () -> Void
    private let didEnd: () -> Void
    private var initialMouseX: CGFloat?
    private var initialWidth: CGFloat?

    init(
        edge: Edge,
        identifier: String,
        currentWidth: @escaping () -> CGFloat,
        clampWidth: @escaping (CGFloat) -> CGFloat,
        applyWidth: @escaping (CGFloat) -> Void,
        didBegin: @escaping () -> Void,
        didEnd: @escaping () -> Void
    ) {
        self.edge = edge
        self.currentWidth = currentWidth
        self.clampWidth = clampWidth
        self.applyWidth = applyWidth
        self.didBegin = didBegin
        self.didEnd = didEnd
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier(identifier)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(String(
            localized: "sidebar.resize.accessibilityLabel",
            defaultValue: "Resize Sidebar"
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        initialMouseX = event.locationInWindow.x
        initialWidth = currentWidth()
        didBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let initialMouseX, let initialWidth else { return }
        let delta = event.locationInWindow.x - initialMouseX
        let candidate: CGFloat
        switch edge {
        case .leftSidebarTrailing:
            candidate = initialWidth + delta
        case .rightSidebarLeading:
            candidate = initialWidth - delta
        }
        applyWidth(clampWidth(candidate))
    }

    override func mouseUp(with event: NSEvent) {
        finishInteraction()
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: Double(currentWidth()))
    }

    override func accessibilityPerformIncrement() -> Bool {
        applyWidth(clampWidth(currentWidth() + 10))
        didEnd()
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        applyWidth(clampWidth(currentWidth() - 10))
        didEnd()
        return true
    }

    private func finishInteraction() {
        guard initialMouseX != nil || initialWidth != nil else { return }
        initialMouseX = nil
        initialWidth = nil
        didEnd()
    }
}

@MainActor
private final class MainWindowNativeTitlebarView: NSView {
    private let dragHandle = WindowDragHandleNSView(doubleClickBehavior: .standardAction)
    private let titleLabel = NSTextField(labelWithString: "")
    private let border = WindowChromeBorder(
        orientation: .horizontal,
        refreshNotificationName: .ghosttyDefaultBackgroundDidChange,
        backgroundColorProvider: { GhosttyBackgroundTheme.currentColor() }
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)

        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        border.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityIdentifier("MainWindowTitle")

        addSubview(dragHandle)
        addSubview(titleLabel)
        addSubview(border)
        NSLayoutConstraint.activate([
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragHandle.topAnchor.constraint(equalTo: topAnchor),
            dragHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, appearance: WindowAppearanceSnapshot) {
        titleLabel.stringValue = title
        titleLabel.textColor = appearance.terminalBackgroundColor.isLightColor
            ? NSColor.black.withAlphaComponent(0.78)
            : NSColor.white.withAlphaComponent(0.82)
        border.refresh()
    }
}

/// AppKit composition root for one cmux main window.
///
/// This controller owns stable child-controller identity and consumes the current
/// ObservableObject model layer through cancellable publisher bridges. The
/// model layer can move to Observation independently without changing window
/// composition or reintroducing a declarative UI host.
@MainActor
final class MainWindowNativeViewController: NSViewController {
    private let updateViewModel: UpdateStateModel
    private let windowId: UUID
    private let tabManager: TabManager
    private let notificationStore: TerminalNotificationStore
    private let sidebarState: SidebarState
    private let sidebarSelectionState: SidebarSelectionState
    private let fileExplorerState: FileExplorerState
    private let cmuxConfigStore: CmuxConfigStore
    private let titlebarControlsLayoutModel: TitlebarControlsLayoutModel
    private let settingsRuntime: SettingsRuntime?

    private let windowChrome = AppWindowChromeComposition()
    private let rootLayoutView = MainWindowNativeRootLayoutView()
    private let rootBackdrop: WindowBackdropLayer
    private let leftSidebarBackdrop: WindowBackdropLayer
    private let rightSidebarBackdrop: WindowBackdropLayer
    private let sidebarClipView = NSView()
    private let centerView = NSView()
    private let workspaceContainer = NSView()
    private let rightSidebarClipView = NSView()
    private let titlebarView = MainWindowNativeTitlebarView()
    private let minimalModeEventSurface = MinimalModeTitlebarEventSurfaceNSView(frame: .zero)
    private let rightSidebarBorder = WindowChromeBorder(
        orientation: .vertical,
        refreshNotificationName: .ghosttyDefaultBackgroundDidChange,
        backgroundColorProvider: { GhosttyBackgroundTheme.currentColor() }
    )

    private let fileExplorerStore = FileExplorerStore()
    private let sessionIndexStore = SessionIndexStore()
    private let renderWorkerClientStore = RenderWorkerClientStore()
    private let backgroundWorkspacePrimeCoordinator = BackgroundWorkspacePrimeCoordinator()
    private let modelRefreshScheduler = MainActorDeferredActionScheduler()
    private let workspaceHandoffFallbackScheduler = MainActorDeferredActionScheduler()

    private lazy var commandPaletteController = MainWindowCommandPaletteController(
        windowId: windowId,
        tabManager: tabManager,
        updateViewModel: updateViewModel,
        notificationStore: notificationStore,
        sidebarState: sidebarState,
        sidebarSelectionState: sidebarSelectionState,
        fileExplorerState: fileExplorerState,
        cmuxConfigStore: cmuxConfigStore,
        hostView: rootLayoutView,
        windowProvider: { [weak self] in self?.view.window },
        openRightSidebarToolPane: { [weak self] mode in
            self?.openRightSidebarToolPane(mode)
        }
    )

    private lazy var sidebarController = SidebarNativeViewController(
        updateViewModel: updateViewModel,
        tabManager: tabManager,
        sidebarSelectionState: sidebarSelectionState,
        cmuxConfigStore: cmuxConfigStore,
        sidebarUnread: notificationStore.sidebarUnread,
        windowID: windowId,
        providerID: effectiveLeftSidebarProviderId,
        renderWorkerClientStore: renderWorkerClientStore,
        titlebarControlsLayoutModel: titlebarControlsLayoutModel,
        onSendFeedback: { [weak self] in self?.presentFeedbackComposer() },
        onToggleSidebar: { [weak sidebarState] in sidebarState?.toggle() },
        onNewTab: { [weak tabManager] in
            guard let tabManager else { return }
            AppDelegate.shared?.performNewWorkspaceAction(
                tabManager: tabManager,
                debugSource: "titlebar.hiddenNewWorkspace"
            )
        }
    )
    private lazy var notificationsController = NotificationsPageViewController(
        notificationStore: notificationStore,
        tabManager: tabManager,
        selection: { [weak sidebarSelectionState] in sidebarSelectionState?.selection ?? .tabs },
        setSelection: { [weak sidebarSelectionState] in sidebarSelectionState?.selection = $0 }
    )
    private lazy var rightSidebarController = RightSidebarNativeViewController(
        tabManager: tabManager,
        fileExplorerStore: fileExplorerStore,
        fileExplorerState: fileExplorerState,
        sessionIndexStore: sessionIndexStore,
        titlebarHeight: RightSidebarChromeMetrics.titlebarHeight,
        windowAppearance: appearance,
        onResumeSession: { [weak tabManager] entry in
            guard let tabManager else { return }
            SessionEntryResumeCoordinator.resume(entry, tabManager: tabManager)
        },
        onOpenFilePreview: { [weak self] path in self?.openFilePreview(path) },
        onOpenAsPane: { [weak self] mode in self?.openRightSidebarToolPane(mode) },
        onClose: { [weak self] in
            guard let self else { return }
            _ = AppDelegate.shared?.closeRightSidebarInActiveMainWindow(preferredWindow: self.view.window)
        }
    )

    private var appearance: WindowAppearanceSnapshot
    private var sidebarVisibleWidthConstraint: NSLayoutConstraint!
    private var sidebarContentWidthConstraint: NSLayoutConstraint!
    private var rightSidebarVisibleWidthConstraint: NSLayoutConstraint!
    private var rightSidebarContentWidthConstraint: NSLayoutConstraint!
    private var centerTopConstraint: NSLayoutConstraint!
    private var titlebarHeightConstraint: NSLayoutConstraint!
    private var leftResizeHandle: MainWindowNativeSidebarResizeHandle!
    private var rightResizeHandle: MainWindowNativeSidebarResizeHandle!
    private var workspaceControllers: [UUID: WorkspaceContentNativeViewController] = [:]
    private var workspaceObservationCancellables: [UUID: AnyCancellable] = [:]
    private var modelCancellables: Set<AnyCancellable> = []
    private var observationTasks: [Task<Void, Never>] = []
    private var backgroundPrimeTask: Task<Void, Never>?
    private var startupRecoveryTask: Task<Void, Never>?
    private var mountedWorkspaceIds: [UUID] = []
    private var previousSelectedWorkspaceId: UUID?
    private var retiringWorkspaceId: UUID?
    private var lastPortalRenderingStatesByWorkspaceId: [UUID: Bool] = [:]
    private var isInteractiveResize = false
    private weak var configuredWindow: NSWindow?

    init(
        updateViewModel: UpdateStateModel,
        windowId: UUID,
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState,
        fileExplorerState: FileExplorerState,
        cmuxConfigStore: CmuxConfigStore,
        titlebarControlsLayoutModel: TitlebarControlsLayoutModel,
        settingsRuntime: SettingsRuntime?
    ) {
        self.updateViewModel = updateViewModel
        self.windowId = windowId
        self.tabManager = tabManager
        self.notificationStore = notificationStore
        self.sidebarState = sidebarState
        self.sidebarSelectionState = sidebarSelectionState
        self.fileExplorerState = fileExplorerState
        self.cmuxConfigStore = cmuxConfigStore
        self.titlebarControlsLayoutModel = titlebarControlsLayoutModel
        self.settingsRuntime = settingsRuntime
        let initialAppearance = AppWindowChromeComposition().appearanceSnapshotFromUserDefaults()
        self.appearance = initialAppearance
        self.rootBackdrop = WindowBackdropLayer(role: .windowRoot, snapshot: initialAppearance)
        self.leftSidebarBackdrop = WindowBackdropLayer(role: .leftSidebar, snapshot: initialAppearance)
        self.rightSidebarBackdrop = WindowBackdropLayer(role: .rightSidebar, snapshot: initialAppearance)
        self.previousSelectedWorkspaceId = tabManager.selectedTabId
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        observationTasks.forEach { $0.cancel() }
        backgroundPrimeTask?.cancel()
        startupRecoveryTask?.cancel()
        modelRefreshScheduler.cancel()
        workspaceHandoffFallbackScheduler.cancel()
    }

    override func loadView() {
        rootLayoutView.owner = self
        configureHierarchy()
        view = MainWindowContentView(contentView: rootLayoutView)
        startObserving()
        refresh(reason: "load")
        scheduleStartupRecovery()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if isInteractiveResize {
            TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: tabManager)
            isInteractiveResize = false
        }
    }

    func teardown() {
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll(keepingCapacity: false)
        workspaceObservationCancellables.removeAll(keepingCapacity: false)
        modelCancellables.removeAll(keepingCapacity: false)
        backgroundPrimeTask?.cancel()
        backgroundPrimeTask = nil
        startupRecoveryTask?.cancel()
        startupRecoveryTask = nil
        modelRefreshScheduler.cancel()
        workspaceHandoffFallbackScheduler.cancel()
        sidebarState.removeVisibilityWillChangeHandler(ownerId: windowId)
        commandPaletteController.teardown()
        sidebarController.teardown()
        rightSidebarController.teardown()
        notificationsController.teardown()
        for controller in workspaceControllers.values {
            controller.teardown()
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        workspaceControllers.removeAll(keepingCapacity: false)
    }

    func rootViewDidMoveToWindow(_ window: NSWindow?) {
        guard window != nil else { return }
        configureWindowIfNeeded()
    }

    func effectiveAppearanceDidChange() {
        refreshAppearance(reason: "effectiveAppearance")
    }

    private func configureHierarchy() {
        rootLayoutView.translatesAutoresizingMaskIntoConstraints = false
        rootLayoutView.wantsLayer = true
        rootLayoutView.layer?.backgroundColor = NSColor.clear.cgColor
        rootLayoutView.setAccessibilityIdentifier("MainWindowNativeRoot")

        for view in [rootBackdrop, sidebarClipView, centerView, rightSidebarClipView, minimalModeEventSurface] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootLayoutView.addSubview(view)
        }
        sidebarClipView.wantsLayer = true
        sidebarClipView.layer?.masksToBounds = true
        rightSidebarClipView.wantsLayer = true
        rightSidebarClipView.layer?.masksToBounds = true
        centerView.wantsLayer = true
        centerView.layer?.masksToBounds = true
        minimalModeEventSurface.translatesAutoresizingMaskIntoConstraints = false

        addChild(sidebarController)
        leftSidebarBackdrop.translatesAutoresizingMaskIntoConstraints = false
        sidebarController.view.translatesAutoresizingMaskIntoConstraints = false
        sidebarClipView.addSubview(leftSidebarBackdrop)
        sidebarClipView.addSubview(sidebarController.view)

        titlebarView.translatesAutoresizingMaskIntoConstraints = false
        workspaceContainer.translatesAutoresizingMaskIntoConstraints = false
        workspaceContainer.wantsLayer = true
        workspaceContainer.layer?.masksToBounds = true
        centerView.addSubview(workspaceContainer)
        centerView.addSubview(titlebarView)

        addChild(notificationsController)
        notificationsController.view.translatesAutoresizingMaskIntoConstraints = false
        centerView.addSubview(notificationsController.view, positioned: .above, relativeTo: workspaceContainer)

        addChild(rightSidebarController)
        rightSidebarBackdrop.translatesAutoresizingMaskIntoConstraints = false
        rightSidebarController.view.translatesAutoresizingMaskIntoConstraints = false
        rightSidebarBorder.translatesAutoresizingMaskIntoConstraints = false
        rightSidebarClipView.addSubview(rightSidebarBackdrop)
        rightSidebarClipView.addSubview(rightSidebarController.view)
        rightSidebarClipView.addSubview(rightSidebarBorder)

        sidebarVisibleWidthConstraint = sidebarClipView.widthAnchor.constraint(equalToConstant: 0)
        sidebarContentWidthConstraint = sidebarController.view.widthAnchor.constraint(
            equalToConstant: CGFloat(SessionPersistencePolicy.defaultSidebarWidth)
        )
        rightSidebarVisibleWidthConstraint = rightSidebarClipView.widthAnchor.constraint(equalToConstant: 0)
        rightSidebarContentWidthConstraint = rightSidebarController.view.widthAnchor.constraint(equalToConstant: 220)
        centerTopConstraint = workspaceContainer.topAnchor.constraint(equalTo: centerView.topAnchor)
        titlebarHeightConstraint = titlebarView.heightAnchor.constraint(equalToConstant: WindowChromeMetrics.appTitlebarHeight)

        NSLayoutConstraint.activate([
            rootBackdrop.leadingAnchor.constraint(equalTo: rootLayoutView.leadingAnchor),
            rootBackdrop.trailingAnchor.constraint(equalTo: rootLayoutView.trailingAnchor),
            rootBackdrop.topAnchor.constraint(equalTo: rootLayoutView.topAnchor),
            rootBackdrop.bottomAnchor.constraint(equalTo: rootLayoutView.bottomAnchor),

            sidebarClipView.leadingAnchor.constraint(equalTo: rootLayoutView.leadingAnchor),
            sidebarClipView.topAnchor.constraint(equalTo: rootLayoutView.topAnchor),
            sidebarClipView.bottomAnchor.constraint(equalTo: rootLayoutView.bottomAnchor),
            sidebarVisibleWidthConstraint,
            leftSidebarBackdrop.leadingAnchor.constraint(equalTo: sidebarClipView.leadingAnchor),
            leftSidebarBackdrop.topAnchor.constraint(equalTo: sidebarClipView.topAnchor),
            leftSidebarBackdrop.bottomAnchor.constraint(equalTo: sidebarClipView.bottomAnchor),
            leftSidebarBackdrop.widthAnchor.constraint(equalTo: sidebarController.view.widthAnchor),
            sidebarController.view.leadingAnchor.constraint(equalTo: sidebarClipView.leadingAnchor),
            sidebarController.view.topAnchor.constraint(equalTo: sidebarClipView.topAnchor),
            sidebarController.view.bottomAnchor.constraint(equalTo: sidebarClipView.bottomAnchor),
            sidebarContentWidthConstraint,

            centerView.leadingAnchor.constraint(equalTo: sidebarClipView.trailingAnchor),
            centerView.trailingAnchor.constraint(equalTo: rightSidebarClipView.leadingAnchor),
            centerView.topAnchor.constraint(equalTo: rootLayoutView.topAnchor),
            centerView.bottomAnchor.constraint(equalTo: rootLayoutView.bottomAnchor),
            titlebarView.leadingAnchor.constraint(equalTo: centerView.leadingAnchor),
            titlebarView.trailingAnchor.constraint(equalTo: centerView.trailingAnchor),
            titlebarView.topAnchor.constraint(equalTo: centerView.topAnchor),
            titlebarHeightConstraint,
            workspaceContainer.leadingAnchor.constraint(equalTo: centerView.leadingAnchor),
            workspaceContainer.trailingAnchor.constraint(equalTo: centerView.trailingAnchor),
            centerTopConstraint,
            workspaceContainer.bottomAnchor.constraint(equalTo: centerView.bottomAnchor),
            notificationsController.view.leadingAnchor.constraint(equalTo: workspaceContainer.leadingAnchor),
            notificationsController.view.trailingAnchor.constraint(equalTo: workspaceContainer.trailingAnchor),
            notificationsController.view.topAnchor.constraint(equalTo: workspaceContainer.topAnchor),
            notificationsController.view.bottomAnchor.constraint(equalTo: workspaceContainer.bottomAnchor),

            rightSidebarClipView.trailingAnchor.constraint(equalTo: rootLayoutView.trailingAnchor),
            rightSidebarClipView.topAnchor.constraint(equalTo: rootLayoutView.topAnchor),
            rightSidebarClipView.bottomAnchor.constraint(equalTo: rootLayoutView.bottomAnchor),
            rightSidebarVisibleWidthConstraint,
            rightSidebarBackdrop.trailingAnchor.constraint(equalTo: rightSidebarClipView.trailingAnchor),
            rightSidebarBackdrop.topAnchor.constraint(equalTo: rightSidebarClipView.topAnchor),
            rightSidebarBackdrop.bottomAnchor.constraint(equalTo: rightSidebarClipView.bottomAnchor),
            rightSidebarBackdrop.widthAnchor.constraint(equalTo: rightSidebarController.view.widthAnchor),
            rightSidebarController.view.trailingAnchor.constraint(equalTo: rightSidebarClipView.trailingAnchor),
            rightSidebarController.view.topAnchor.constraint(equalTo: rightSidebarClipView.topAnchor),
            rightSidebarController.view.bottomAnchor.constraint(equalTo: rightSidebarClipView.bottomAnchor),
            rightSidebarContentWidthConstraint,
            rightSidebarBorder.leadingAnchor.constraint(equalTo: rightSidebarClipView.leadingAnchor),
            rightSidebarBorder.topAnchor.constraint(equalTo: rightSidebarClipView.topAnchor),
            rightSidebarBorder.bottomAnchor.constraint(equalTo: rightSidebarClipView.bottomAnchor),

            minimalModeEventSurface.leadingAnchor.constraint(equalTo: rootLayoutView.leadingAnchor),
            minimalModeEventSurface.trailingAnchor.constraint(equalTo: rootLayoutView.trailingAnchor),
            minimalModeEventSurface.topAnchor.constraint(equalTo: rootLayoutView.topAnchor),
            minimalModeEventSurface.bottomAnchor.constraint(equalTo: rootLayoutView.bottomAnchor),
        ])

        configureResizeHandles()
        _ = commandPaletteController
    }

    private func configureResizeHandles() {
        leftResizeHandle = MainWindowNativeSidebarResizeHandle(
            edge: .leftSidebarTrailing,
            identifier: "SidebarResizer",
            currentWidth: { [weak self] in self?.sidebarContentWidthConstraint.constant ?? 0 },
            clampWidth: { [weak self] candidate in
                guard let self else { return candidate }
                return MainWindowSidebarWidthPolicy.resolvedLeftWidth(
                    candidate,
                    availableWidth: self.rootLayoutView.bounds.width
                )
            },
            applyWidth: { [weak self] in self?.applyLeftSidebarWidth($0, persist: false) },
            didBegin: { [weak self] in self?.beginInteractiveResize() },
            didEnd: { [weak self] in self?.endInteractiveResize(persistLeft: true) }
        )
        rightResizeHandle = MainWindowNativeSidebarResizeHandle(
            edge: .rightSidebarLeading,
            identifier: "RightSidebarResizer",
            currentWidth: { [weak self] in self?.rightSidebarContentWidthConstraint.constant ?? 0 },
            clampWidth: { [weak self] candidate in
                guard let self else { return candidate }
                return MainWindowSidebarWidthPolicy.resolvedRightWidth(
                    candidate,
                    availableWidth: self.rootLayoutView.bounds.width
                )
            },
            applyWidth: { [weak self] in self?.applyRightSidebarWidth($0, persist: false) },
            didBegin: { [weak self] in self?.beginInteractiveResize() },
            didEnd: { [weak self] in self?.endInteractiveResize(persistRight: true) }
        )
        rootLayoutView.addSubview(leftResizeHandle)
        rootLayoutView.addSubview(rightResizeHandle)
        NSLayoutConstraint.activate([
            leftResizeHandle.centerXAnchor.constraint(equalTo: sidebarClipView.trailingAnchor),
            leftResizeHandle.topAnchor.constraint(equalTo: rootLayoutView.topAnchor),
            leftResizeHandle.bottomAnchor.constraint(equalTo: rootLayoutView.bottomAnchor),
            leftResizeHandle.widthAnchor.constraint(equalToConstant: SidebarResizeInteraction.totalHitWidth),
            rightResizeHandle.centerXAnchor.constraint(equalTo: rightSidebarClipView.leadingAnchor),
            rightResizeHandle.topAnchor.constraint(equalTo: rootLayoutView.topAnchor),
            rightResizeHandle.bottomAnchor.constraint(equalTo: rootLayoutView.bottomAnchor),
            rightResizeHandle.widthAnchor.constraint(equalToConstant: SidebarResizeInteraction.totalHitWidth),
        ])
    }

    private func startObserving() {
        sidebarState.installVisibilityWillChangeHandler(ownerId: windowId) { [weak self] isVisible in
            guard !isVisible else { return }
            self?.restoreMainPanelFocusAfterSidebarHiddenIfNeeded()
        }

        observeModel(tabManager.objectWillChange, reason: "tabManager")
        observeModel(sidebarState.objectWillChange, reason: "sidebarState")
        observeModel(sidebarSelectionState.objectWillChange, reason: "sidebarSelection")
        observeModel(fileExplorerState.objectWillChange, reason: "rightSidebarState")
        observeModel(cmuxConfigStore.objectWillChange, reason: "config")
        observeNotification(UserDefaults.didChangeNotification) { controller, _ in
            controller.refresh(reason: "defaults")
        }
        observeNotification(.ghosttyDefaultBackgroundDidChange) { controller, _ in
            controller.refreshAppearance(reason: "terminalBackground")
        }
        observeNotification(.systemAppearanceDidChange) { controller, _ in
            controller.refreshAppearance(reason: "systemAppearance")
        }
        observeNotification(.ghosttyDidSetTitle) { controller, notification in
            guard controller.tabManager.shouldScheduleRawTitleRefresh(
                forWorkspaceId: GhosttyTitleChange(notification: notification)?.tabId
            ) else { return }
            controller.refreshTitlebar()
        }
        observeNotification(.workspaceTitleDidChange) { controller, notification in
            guard notification.object as? TabManager === controller.tabManager,
                  controller.tabManager.shouldRefreshTitleChrome(for: notification) else { return }
            controller.refreshTitlebar()
        }
        observeNotification(.workspaceGroupNameDidChange) { controller, notification in
            guard notification.object as? TabManager === controller.tabManager else { return }
            controller.refreshTitlebar()
        }
        observeNotification(.ghosttyDidFocusTab) { controller, _ in
            controller.sidebarSelectionState.selection = .tabs
            controller.refreshTitlebar()
        }
        observeNotification(.ghosttyDidFocusSurface) { controller, notification in
            guard let workspaceId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  workspaceId == controller.tabManager.selectedTabId else { return }
            controller.completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: workspaceId, reason: "focus")
            controller.refreshTitlebar()
        }
        observeNotification(.ghosttyDidBecomeFirstResponderSurface) { controller, notification in
            guard let workspaceId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            controller.completeWorkspaceHandoffIfNeeded(
                focusedWorkspaceId: workspaceId,
                reason: "first_responder"
            )
        }
        observeNotification(.browserDidBecomeFirstResponderWebView) { controller, _ in
            guard let workspaceId = controller.tabManager.selectedTabId else { return }
            controller.completeWorkspaceHandoffIfNeeded(
                focusedWorkspaceId: workspaceId,
                reason: "browser_first_responder"
            )
        }
        observeNotification(.browserDidFocusAddressBar) { controller, _ in
            guard let workspaceId = controller.tabManager.selectedTabId else { return }
            controller.completeWorkspaceHandoffIfNeeded(
                focusedWorkspaceId: workspaceId,
                reason: "browser_address_bar"
            )
        }
        observeNotification(NSWindow.didResizeNotification) { controller, notification in
            guard notification.object as? NSWindow === controller.view.window else { return }
            controller.clampWidthsToAvailableSpace()
        }
        observeNotification(NSWindow.didEnterFullScreenNotification) { controller, notification in
            guard notification.object as? NSWindow === controller.view.window else { return }
            controller.refreshPresentationMode()
        }
        observeNotification(NSWindow.didExitFullScreenNotification) { controller, notification in
            guard notification.object as? NSWindow === controller.view.window else { return }
            controller.refreshPresentationMode()
        }
        observeNotification(.feedbackComposerRequested) { controller, notification in
            let requestedWindow = notification.object as? NSWindow
            guard requestedWindow == nil || requestedWindow === controller.view.window else { return }
            controller.presentFeedbackComposer()
        }
        observeNotification(.commandPaletteToggleRequested) { controller, notification in
            guard controller.commandPaletteController.handles(notification) else { return }
            controller.commandPaletteController.toggleCommands()
        }
        observeNotification(.commandPaletteRequested) { controller, notification in
            guard controller.commandPaletteController.handles(notification) else { return }
            controller.commandPaletteController.openCommands()
        }
        observeNotification(.commandPaletteSwitcherRequested) { controller, notification in
            guard controller.commandPaletteController.handles(notification) else { return }
            controller.commandPaletteController.openSwitcher()
        }
        observeNotification(.commandPaletteSubmitRequested) { controller, notification in
            guard controller.commandPaletteController.handles(notification) else { return }
            controller.commandPaletteController.submit()
        }
        observeNotification(.commandPaletteDismissRequested) { controller, notification in
            guard controller.commandPaletteController.handles(notification) else { return }
            controller.commandPaletteController.dismiss()
        }
        observeNotification(.commandPaletteMoveSelection) { controller, notification in
            guard controller.commandPaletteController.handles(notification),
                  let delta = notification.userInfo?["delta"] as? Int,
                  delta != 0 else { return }
            controller.commandPaletteController.moveSelection(by: delta)
        }
        observeNotification(.commandPaletteRenameTabRequested) { controller, notification in
            guard controller.commandPaletteController.handles(notification) else { return }
            controller.commandPaletteController.openRenameTab()
        }
        observeNotification(.commandPaletteRenameWorkspaceRequested) { controller, notification in
            guard controller.commandPaletteController.handles(notification) else { return }
            controller.commandPaletteController.openRenameWorkspace()
        }
        observeNotification(.commandPaletteEditWorkspaceDescriptionRequested) { controller, notification in
            guard controller.commandPaletteController.handles(notification) else { return }
            controller.commandPaletteController.openWorkspaceDescription()
        }
        observeNotification(.commandPaletteRenameInputInteractionRequested) { controller, notification in
            guard controller.commandPaletteController.handles(notification) else { return }
            controller.commandPaletteController.handleRenameInputInteraction()
        }
        observeNotification(.commandPaletteRenameInputDeleteBackwardRequested) { controller, notification in
            guard controller.commandPaletteController.handles(notification) else { return }
            controller.commandPaletteController.handleRenameDeleteBackwardFromEmptyInput()
        }
    }

    private func observeNotification(
        _ name: Notification.Name,
        handler: @escaping @MainActor (MainWindowNativeViewController, Notification) -> Void
    ) {
        observationTasks.append(Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(named: name)
            for await notification in notifications {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                handler(self, notification)
            }
        })
    }

    private func observeModel(
        _ publisher: ObservableObjectPublisher,
        reason: String
    ) {
        publisher
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleModelRefresh(reason: reason)
                }
            }
            .store(in: &modelCancellables)
    }

    private func scheduleModelRefresh(reason: String) {
        modelRefreshScheduler.schedule(zeroDelayPolicy: .yieldOnce) { [weak self] in
            self?.refresh(reason: reason)
        }
    }

    private func refresh(reason: String) {
        guard isViewLoaded else { return }
        let selectedWorkspaceId = tabManager.selectedTabId
        if previousSelectedWorkspaceId != selectedWorkspaceId {
            startWorkspaceHandoffIfNeeded(newSelectedWorkspaceId: selectedWorkspaceId)
        }
        refreshAppearance(reason: reason)
        refreshProvider()
        refreshPresentationMode()
        refreshSidebarWidths()
        reconcileWorkspaceObservers()
        reconcileWorkspaceControllers()
        refreshSelectionPresentation()
        refreshRightSidebar()
        syncFileExplorerDirectory()
        refreshTitlebar()
        primeBackgroundWorkspacesIfNeeded()
        tabManager.applyWindowBackgroundForSelectedTab()
    }

    private func refreshProvider() {
        sidebarController.updateProviderID(effectiveLeftSidebarProviderId)
        sidebarController.setPresentationActive(sidebarState.isVisible)
    }

    private var effectiveLeftSidebarProviderId: String {
        let selected = UserDefaults.standard.string(forKey: CmuxExtensionSidebarSelection.defaultsKey)
            ?? CmuxExtensionSidebarSelection.defaultProviderId
        return CmuxExtensionSidebarSelection.effectiveProviderId(
            selected,
            extensionsEnabled: CmuxExtensionSidebarSelection.isEnabled,
            customSidebarsEnabled: CmuxExtensionSidebarSelection.customSidebarsEnabled
        )
    }

    private func refreshPresentationMode() {
        let isMinimal = WorkspacePresentationModeSettings.isMinimal()
        let isFullScreen = view.window?.styleMask.contains(.fullScreen) == true
        let titlebarHeight: CGFloat = isMinimal ? 0 : WindowChromeMetrics.appTitlebarHeight
        titlebarHeightConstraint.constant = titlebarHeight
        centerTopConstraint.constant = titlebarHeight
        titlebarView.isHidden = isMinimal
        minimalModeEventSurface.isEnabled = isMinimal && !isFullScreen
        setMinimalModeSidebarTitlebarControlsAvailable(sidebarState.isVisible, in: view.window)
        let tabBarInset: CGFloat = isMinimal && !sidebarState.isVisible && !isFullScreen
            ? CGFloat(MinimalModeTitlebarDebugSettings.trafficLightTabBarLeadingInset())
            : 0
        tabManager.syncWorkspaceTabBarLeadingInset(tabBarInset)
        if let window = view.window {
            windowChrome.nativeTitlebarBackdropCoordinator.setTitlebarControlsHidden(
                isFullScreen,
                in: window,
                isMinimalMode: isMinimal
            )
            AppDelegate.shared?.applyWindowDecorations(to: window)
        }
    }

    private func refreshSidebarWidths() {
        let availableWidth = max(rootLayoutView.bounds.width, view.window?.contentLayoutRect.width ?? 0)
        let leftWidth = MainWindowSidebarWidthPolicy.resolvedLeftWidth(
            sidebarState.persistedWidth,
            availableWidth: availableWidth
        )
        applyLeftSidebarWidth(leftWidth, persist: true)
        let rightWidth = MainWindowSidebarWidthPolicy.resolvedRightWidth(
            fileExplorerState.width,
            availableWidth: availableWidth
        )
        applyRightSidebarWidth(rightWidth, persist: true)
    }

    private func applyLeftSidebarWidth(_ width: CGFloat, persist: Bool) {
        sidebarContentWidthConstraint.constant = width
        sidebarVisibleWidthConstraint.constant = sidebarState.isVisible ? width : 0
        sidebarClipView.isHidden = !sidebarState.isVisible
        leftResizeHandle?.isHidden = !sidebarState.isVisible
        if persist, abs(sidebarState.persistedWidth - width) > 0.5 {
            sidebarState.persistedWidth = width
        }
        invalidatePortalGeometry()
    }

    private func applyRightSidebarWidth(_ width: CGFloat, persist: Bool) {
        rightSidebarContentWidthConstraint.constant = width
        rightSidebarVisibleWidthConstraint.constant = fileExplorerState.isVisible ? width : 0
        rightSidebarClipView.isHidden = !fileExplorerState.isVisible
        rightResizeHandle?.isHidden = !fileExplorerState.isVisible
        if persist, abs(fileExplorerState.width - width) > 0.5 {
            fileExplorerState.width = width
        }
        invalidatePortalGeometry()
    }

    private func clampWidthsToAvailableSpace() {
        refreshSidebarWidths()
        rootLayoutView.needsLayout = true
    }

    private func beginInteractiveResize() {
        guard !isInteractiveResize else { return }
        isInteractiveResize = true
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(owner: tabManager, in: view.window)
    }

    private func endInteractiveResize(persistLeft: Bool = false, persistRight: Bool = false) {
        if persistLeft {
            sidebarState.persistedWidth = sidebarContentWidthConstraint.constant
        }
        if persistRight {
            fileExplorerState.width = rightSidebarContentWidthConstraint.constant
        }
        if isInteractiveResize {
            TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: tabManager)
            isInteractiveResize = false
        }
        invalidatePortalGeometry()
    }

    private func reconcileWorkspaceObservers() {
        let workspacesById = Dictionary(uniqueKeysWithValues: tabManager.tabs.map { ($0.id, $0) })
        for id in Array(workspaceObservationCancellables.keys) where workspacesById[id] == nil {
            workspaceObservationCancellables[id] = nil
        }
        for workspace in tabManager.tabs where workspaceObservationCancellables[workspace.id] == nil {
            let id = workspace.id
            workspaceObservationCancellables[id] = workspace.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.workspaceDidChange(id: id)
                }
            }
        }
    }

    private func workspaceDidChange(id: UUID) {
        guard tabManager.tabs.contains(where: { $0.id == id }) else { return }
        reconcileWorkspaceControllers()
        syncFileExplorerDirectory()
        if id == tabManager.selectedTabId {
            refreshTitlebar()
        }
    }

    private func reconcileWorkspaceControllers() {
        let orderedWorkspaceIds = tabManager.tabs.map(\.id)
        let handoffPinnedIds = retiringWorkspaceId.map { Set([$0]) } ?? []
        let pinnedIds = handoffPinnedIds
            .union(tabManager.mountedBackgroundWorkspaceLoadIds)
            .union(tabManager.debugPinnedWorkspaceLoadIds)
        let shouldKeepHandoffPair = tabManager.isWorkspaceCycleHot && !handoffPinnedIds.isEmpty
        let baseMaximum = shouldKeepHandoffPair
            ? WorkspaceMountPlan.maxMountedWorkspacesDuringCycle
            : WorkspaceMountPlan.maxMountedWorkspaces
        let selectedCount = tabManager.selectedTabId == nil ? 0 : 1
        let maximum = max(baseMaximum, selectedCount + pinnedIds.count)
        let previousMountedIds = mountedWorkspaceIds
        mountedWorkspaceIds = WorkspaceMountPlan(
            current: mountedWorkspaceIds,
            selected: tabManager.selectedTabId,
            pinnedIds: pinnedIds,
            orderedTabIds: orderedWorkspaceIds,
            isCycleHot: tabManager.isWorkspaceCycleHot,
            maxMounted: maximum
        ).mountedWorkspaceIds

        let mountedSet = Set(mountedWorkspaceIds)
        for id in previousMountedIds where !mountedSet.contains(id) {
            unmountWorkspace(id: id)
        }
        for workspace in tabManager.tabs where mountedSet.contains(workspace.id) {
            mountWorkspaceIfNeeded(workspace)
        }

        let states = WorkspacePortalRenderingPlan(
            previousStatesByWorkspaceId: lastPortalRenderingStatesByWorkspaceId,
            mountedWorkspaceIds: mountedSet,
            orderedWorkspaceIds: orderedWorkspaceIds
        )
        let changes = states.applying(to: &lastPortalRenderingStatesByWorkspaceId)
        let workspacesById = Dictionary(uniqueKeysWithValues: tabManager.tabs.map { ($0.id, $0) })
        for change in changes {
            workspacesById[change.workspaceId]?.setPortalRenderingEnabled(
                change.isEnabled,
                reason: "workspaceMount.nativeRoot"
            )
        }
        updateWorkspaceControllerConfigurations()
    }

    private func mountWorkspaceIfNeeded(_ workspace: Workspace) {
        guard workspaceControllers[workspace.id] == nil else { return }
        let controller = WorkspaceContentNativeViewController(
            configuration: workspaceConfiguration(for: workspace)
        )
        workspaceControllers[workspace.id] = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        workspaceContainer.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: workspaceContainer.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: workspaceContainer.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: workspaceContainer.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: workspaceContainer.bottomAnchor),
        ])
    }

    private func unmountWorkspace(id: UUID) {
        guard let controller = workspaceControllers.removeValue(forKey: id) else { return }
        controller.teardown()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func updateWorkspaceControllerConfigurations() {
        let selectedId = tabManager.selectedTabId
        for workspace in tabManager.tabs {
            guard let controller = workspaceControllers[workspace.id] else { continue }
            let isSelected = workspace.id == selectedId
            let isRetiring = workspace.id == retiringWorkspaceId
            let presentation = MountedWorkspacePresentation.resolve(
                isSelectedWorkspace: isSelected,
                isRetiringWorkspace: isRetiring
            )
            controller.update(configuration: workspaceConfiguration(for: workspace))
            controller.view.isHidden = !presentation.isRenderedVisible
            controller.view.alphaValue = CGFloat(presentation.renderOpacity)
            controller.view.setAccessibilityHidden(!presentation.isRenderedVisible)
            if isSelected {
                workspaceContainer.addSubview(controller.view, positioned: .above, relativeTo: nil)
            }
        }
    }

    private func workspaceConfiguration(for workspace: Workspace) -> WorkspaceContentNativeConfiguration {
        let isSelected = workspace.id == tabManager.selectedTabId
        let isRetiring = workspace.id == retiringWorkspaceId
        let presentation = MountedWorkspacePresentation.resolve(
            isSelectedWorkspace: isSelected,
            isRetiringWorkspace: isRetiring
        )
        let storedMaximum = UserDefaults.standard.double(forKey: SessionContentWidthSettings.maxWidthKey)
        let storedAlignment = UserDefaults.standard.string(forKey: SessionContentWidthSettings.alignmentKey)
            ?? SessionContentAlignment.center.rawValue
        return WorkspaceContentNativeConfiguration(
            workspace: workspace,
            notificationStore: notificationStore,
            isWorkspaceVisible: presentation.isPanelVisible,
            isWorkspaceInputActive: isSelected,
            rightSidebarOwnsInputFocus: fileExplorerState.rightSidebarOwnsInputFocus,
            workspacePortalPriority: isSelected ? 2 : (isRetiring ? 1 : 0),
            windowAppearance: appearance,
            settingsRuntime: settingsRuntime,
            sessionContentWidthPresentation: SessionContentWidthPresentation(
                storedMaximumWidth: storedMaximum,
                storedAlignment: storedAlignment
            ),
            onThemeRefreshRequest: { [weak self, workspaceId = workspace.id] _, _, _, _ in
                guard self?.tabManager.selectedTabId == workspaceId else { return }
                self?.refreshAppearance(reason: "workspaceTheme")
            }
        )
    }

    private func refreshSelectionPresentation() {
        let showsWorkspaces = sidebarSelectionState.selection == .tabs
        workspaceContainer.isHidden = !showsWorkspaces
        workspaceContainer.setAccessibilityHidden(!showsWorkspaces)
        notificationsController.view.isHidden = showsWorkspaces
        notificationsController.view.setAccessibilityHidden(showsWorkspaces)
        notificationsController.updateSelection(
            selection: { [weak sidebarSelectionState] in sidebarSelectionState?.selection ?? .tabs },
            setSelection: { [weak sidebarSelectionState] in sidebarSelectionState?.selection = $0 }
        )
    }

    private func startWorkspaceHandoffIfNeeded(newSelectedWorkspaceId: UUID?) {
        let oldSelectedWorkspaceId = previousSelectedWorkspaceId
        previousSelectedWorkspaceId = newSelectedWorkspaceId
        guard let oldSelectedWorkspaceId,
              let newSelectedWorkspaceId,
              oldSelectedWorkspaceId != newSelectedWorkspaceId else {
            completeWorkspaceHandoff(reason: "no_handoff")
            return
        }
        retiringWorkspaceId = oldSelectedWorkspaceId
        workspaceHandoffFallbackScheduler.cancel()
        if canCompleteWorkspaceHandoffImmediately(for: newSelectedWorkspaceId) {
            completeWorkspaceHandoff(reason: "ready")
            return
        }
        workspaceHandoffFallbackScheduler.schedule(after: .milliseconds(150)) { [weak self] in
            self?.completeWorkspaceHandoff(reason: "timeout")
        }
    }

    private func completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: UUID, reason: String) {
        guard focusedWorkspaceId == tabManager.selectedTabId, retiringWorkspaceId != nil else { return }
        completeWorkspaceHandoff(reason: reason)
    }

    private func canCompleteWorkspaceHandoffImmediately(for workspaceId: UUID) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return true }
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.browserPanel(for: focusedPanelId) != nil {
            return true
        }
        return workspace.hasLoadedTerminalSurface()
    }

    private func completeWorkspaceHandoff(reason: String) {
        workspaceHandoffFallbackScheduler.cancel()
        if let retiringWorkspaceId,
           let workspace = tabManager.tabs.first(where: { $0.id == retiringWorkspaceId }) {
            workspace.setPortalRenderingEnabled(false, reason: "workspaceHandoff.nativeRoot")
            lastPortalRenderingStatesByWorkspaceId[workspace.id] = false
        }
        retiringWorkspaceId = nil
        tabManager.completePendingWorkspaceUnfocus(reason: reason)
        if isViewLoaded {
            reconcileWorkspaceControllers()
        }
    }

    private func refreshRightSidebar() {
        rightSidebarController.update(
            tabManager: tabManager,
            fileExplorerStore: fileExplorerStore,
            fileExplorerState: fileExplorerState,
            sessionIndexStore: sessionIndexStore,
            titlebarHeight: RightSidebarChromeMetrics.titlebarHeight,
            windowAppearance: appearance,
            onResumeSession: { [weak tabManager] entry in
                guard let tabManager else { return }
                SessionEntryResumeCoordinator.resume(entry, tabManager: tabManager)
            },
            onOpenFilePreview: { [weak self] path in self?.openFilePreview(path) },
            onOpenAsPane: { [weak self] mode in self?.openRightSidebarToolPane(mode) },
            onClose: { [weak self] in
                guard let self else { return }
                _ = AppDelegate.shared?.closeRightSidebarInActiveMainWindow(preferredWindow: self.view.window)
            }
        )
        if !fileExplorerState.isVisible {
            _ = AppDelegate.shared?.restoreTerminalFocusAfterRightSidebarHidden(in: view.window)
        }
    }

    private func syncFileExplorerDirectory() {
        guard let workspace = tabManager.selectedWorkspace else {
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            fileExplorerStore.applyWorkspaceRoot(.none)
            return
        }
        fileExplorerStore.showHiddenFiles = true
        if workspace.usesRemoteDirectoryProvenance {
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            guard shouldSyncFileExplorerStore,
                  let config = workspace.remoteConfiguration,
                  config.transport == .ssh else {
                fileExplorerStore.applyWorkspaceRoot(.none)
                return
            }
            fileExplorerStore.applyWorkspaceRoot(.remoteSSH(
                workspaceId: workspace.id,
                connection: SSHFileExplorerConnection(
                    destination: config.destination,
                    port: config.port,
                    identityFile: config.identityFile,
                    sshOptions: config.sshOptions
                ),
                displayTarget: config.displayTarget,
                rootPath: workspace.trustedRemoteCurrentDirectory,
                isAvailable: workspace.remoteConnectionState == .connected,
                unavailableDetail: workspace.remoteConnectionDetail ?? workspace.remoteDaemonStatus.detail
            ))
            return
        }
        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else {
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            fileExplorerStore.applyWorkspaceRoot(.none)
            return
        }
        sessionIndexStore.setCurrentDirectoryIfChanged(directory)
        guard shouldSyncFileExplorerStore else {
            fileExplorerStore.applyWorkspaceRoot(.none)
            return
        }
        fileExplorerStore.applyWorkspaceRoot(.local(workspaceId: workspace.id, path: directory))
    }

    private var shouldSyncFileExplorerStore: Bool {
        FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
            isRightSidebarVisible: fileExplorerState.isVisible,
            mode: fileExplorerState.mode
        )
    }

    private func openRightSidebarToolPane(_ mode: RightSidebarMode) {
        guard mode.canOpenAsPane,
              let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            NSSound.beep()
            return
        }
        sidebarSelectionState.selection = .tabs
        workspace.clearSplitZoom()
        _ = workspace.openOrFocusRightSidebarToolSurface(inPane: paneId, mode: mode, focus: true)
    }

    private func openFilePreview(_ filePath: String) {
        guard let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else { return }
        sidebarSelectionState.selection = .tabs
        if workspace.isRemoteWorkspace {
            Task { @MainActor [weak workspace, fileExplorerStore] in
                guard let workspace else { return }
                do {
                    let localURL = try await fileExplorerStore.materializeRemoteFileForPreview(path: filePath)
                    _ = workspace.openFileSurfaces(
                        inPane: paneId,
                        filePaths: [localURL.path],
                        focus: true,
                        reuseExisting: true
                    )
                } catch {
                    NSSound.beep()
                }
            }
            return
        }
        _ = workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [filePath],
            focus: true,
            reuseExisting: true
        )
    }

    private func refreshTitlebar() {
        let title: String
        if let workspace = tabManager.selectedWorkspace {
            title = tabManager.resolvedWorkspaceDisplayTitle(for: workspace)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = ""
        }
        titlebarView.update(title: title, appearance: appearance)
    }

    private func refreshAppearance(reason: String) {
        appearance = windowChrome.appearanceSnapshotFromUserDefaults()
        rootBackdrop.update(role: .windowRoot, snapshot: appearance)
        leftSidebarBackdrop.update(role: .leftSidebar, snapshot: appearance)
        rightSidebarBackdrop.update(role: .rightSidebar, snapshot: appearance)
        rightSidebarBorder.refresh()
        refreshTitlebar()
        updateWorkspaceControllerConfigurations()
        guard let window = viewIfLoaded?.window else { return }
        let result = windowChrome.backdropController.apply(
            snapshot: appearance,
            to: window,
            windowBackgroundPolicy: windowChrome.windowBackgroundPolicy
        )
        windowChrome.nativeTitlebarBackdropCoordinator.syncNativeTitlebarBackdrop(
            in: window,
            enabled: true,
            usesGlassStyle: result.usesWindowGlass
        )
        if result.didChangeGlassRoot {
            invalidatePortalGeometry()
        }
#if DEBUG
        cmuxDebugLog("nativeRoot.appearance reason=\(reason) glass=\(result.usesWindowGlass ? 1 : 0)")
#endif
    }

    private func configureWindowIfNeeded() {
        guard let window = view.window else { return }
        if configuredWindow !== window {
            configuredWindow = window
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            configureCmuxMainWindowDragBehavior(window)
        }
        refreshAppearance(reason: "windowAttach")
        refreshPresentationMode()
        AppDelegate.shared?.attachUpdateAccessory(to: window)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        installFileDropOverlay(on: window, tabManager: tabManager)
    }

    private func invalidatePortalGeometry() {
        guard let window = viewIfLoaded?.window else { return }
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
    }

    private func restoreMainPanelFocusAfterSidebarHiddenIfNeeded() {
        guard let window = viewIfLoaded?.window,
              let responderView = window.firstResponder as? NSView,
              responderView === sidebarController.view
                || responderView.isDescendant(of: sidebarController.view) else { return }
        _ = window.makeFirstResponder(nil)
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else { return }
        AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
            workspaceId: workspace.id,
            panelId: panelId,
            in: window
        )
        workspace.focusPanel(panelId, focusIntent: panel.preferredFocusIntentForActivation())
    }

    private func presentFeedbackComposer() {
        FeedbackComposerBridge().openComposer(in: viewIfLoaded?.window)
    }

    private func primeBackgroundWorkspacesIfNeeded() {
        guard backgroundWorkspacePrimeCoordinator.taskKey(for: tabManager) else {
            backgroundPrimeTask?.cancel()
            backgroundPrimeTask = nil
            return
        }
        guard backgroundPrimeTask == nil else { return }
        let coordinator = backgroundWorkspacePrimeCoordinator
        let tabManager = tabManager
        backgroundPrimeTask = Task { @MainActor [weak self] in
            await coordinator.primePendingBackgroundWorkspaces(tabManager: tabManager)
            guard !Task.isCancelled else { return }
            self?.backgroundPrimeTask = nil
            self?.reconcileWorkspaceControllers()
        }
    }

    private func scheduleStartupRecovery() {
        startupRecoveryTask?.cancel()
        startupRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self else { return }
            if self.tabManager.tabs.isEmpty {
                self.tabManager.addWorkspace()
            }
            if self.tabManager.selectedTabId == nil
                || !self.tabManager.tabs.contains(where: { $0.id == self.tabManager.selectedTabId }) {
                self.tabManager.selectedTabId = self.tabManager.tabs.first?.id
            }
            self.refresh(reason: "startupRecovery")
        }
    }
}
