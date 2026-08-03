import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxSettingsUI
import CmuxTerminal
import CmuxWorkspaces
import Combine
import Foundation
import Observation

enum WorkspacePanelVisibilityPolicy {
    nonisolated static func panelVisibleInUI(
        isWorkspaceVisible: Bool,
        paneHasSelectedTab: Bool,
        isSelectedInPane: Bool,
        isFocused: Bool
    ) -> Bool {
        guard isWorkspaceVisible else { return false }
        return isSelectedInPane || (isFocused && !paneHasSelectedTab)
    }

    nonisolated static func visiblePanelIdForRenderedPane(
        paneId: UUID,
        selectedPanelId: UUID?,
        firstPanelId: UUID?,
        focusedPanelId: UUID?,
        focusedPanelPaneId: UUID?
    ) -> UUID? {
        if let selectedPanelId {
            return selectedPanelId
        }
        if focusedPanelPaneId == paneId, let focusedPanelId {
            return focusedPanelId
        }
        return firstPanelId
    }
}

@MainActor
final class TmuxWorkspacePaneOverlayModel {
    private(set) var unreadRects: [CGRect] = []
    private(set) var flashRect: CGRect?
    private(set) var activePaneBorderRect: CGRect?
    private(set) var activePaneBorderColorHex: String?
    private(set) var flashStartedAt: Date?
    private(set) var flashReason: WorkspaceAttentionFlashReason?

    private var currentWorkspaceId: UUID?
    private var lastFlashTokenByWorkspaceId: [UUID: UInt64] = [:]

    func apply(
        _ state: TmuxWorkspacePaneOverlayRenderState,
        now: () -> Date = Date.init
    ) {
        unreadRects = state.unreadRects
        flashRect = state.flashRect
        activePaneBorderRect = state.activePaneBorderRect
        activePaneBorderColorHex = state.activePaneBorderColorHex
        flashReason = state.flashReason

        let didChangeWorkspace = currentWorkspaceId != state.workspaceId
        let previousFlashToken = lastFlashTokenByWorkspaceId[state.workspaceId]
        let didChangeFlashToken = previousFlashToken.map { state.flashToken != $0 }
            ?? (state.flashToken > 0)
        if didChangeFlashToken, state.flashRect != nil {
            flashStartedAt = now()
        } else if didChangeWorkspace {
            flashStartedAt = nil
        }
        currentWorkspaceId = state.workspaceId
        if (previousFlashToken == nil && state.flashToken == 0)
            || !didChangeFlashToken
            || state.flashRect != nil {
            lastFlashTokenByWorkspaceId[state.workspaceId] = state.flashToken
        }
    }

    func clear() {
        unreadRects = []
        flashRect = nil
        activePaneBorderRect = nil
        activePaneBorderColorHex = nil
        flashStartedAt = nil
        flashReason = nil
        currentWorkspaceId = nil
        lastFlashTokenByWorkspaceId = [:]
    }
}

@MainActor
struct WorkspaceContentNativeConfiguration {
    let workspace: Workspace
    let notificationStore: TerminalNotificationStore
    var isWorkspaceVisible: Bool
    var isWorkspaceInputActive: Bool
    var rightSidebarOwnsInputFocus: Bool
    var workspacePortalPriority: Int
    var windowAppearance: WindowAppearanceSnapshot
    var settingsRuntime: SettingsRuntime?
    var sessionContentWidthPresentation: SessionContentWidthPresentation
    var onThemeRefreshRequest: ((String, UInt64?, String?, String?) -> Void)?
}

@MainActor
private final class WorkspaceContentPresentationContext {
    var configuration: WorkspaceContentNativeConfiguration
    var appearance: PanelAppearance
    var splitContentActive: Bool
    private var contentControllers: [ObjectIdentifier: WeakWorkspaceContentController] = [:]

    init(
        configuration: WorkspaceContentNativeConfiguration,
        appearance: PanelAppearance
    ) {
        self.configuration = configuration
        self.appearance = appearance
        splitContentActive = configuration.workspace.layoutMode != .canvas
    }

    func register(_ controller: WorkspaceBonsplitContentController) {
        contentControllers[ObjectIdentifier(controller)] = WeakWorkspaceContentController(controller)
        pruneControllers()
    }

    func teardownSplitContent() {
        for box in contentControllers.values {
            box.controller?.teardown()
        }
        contentControllers.removeAll(keepingCapacity: false)
    }

    private func pruneControllers() {
        contentControllers = contentControllers.filter { $0.value.controller != nil }
    }
}

@MainActor
private final class WeakWorkspaceContentController {
    weak var controller: WorkspaceBonsplitContentController?

    init(_ controller: WorkspaceBonsplitContentController) {
        self.controller = controller
    }
}

@MainActor
final class WorkspaceContentNativeViewController: NSViewController {
    private struct DeferredThemeRefresh {
        let reason: String
        let backgroundOverride: NSColor?
        let backgroundEventId: UInt64?
        let backgroundSource: String?
        let notificationPayloadHex: String?
        let forceInitialApply: Bool
    }

    private enum InstalledMode {
        case split
        case canvas
    }

    private let context: WorkspaceContentPresentationContext
    private let bonsplitViewController: BonsplitViewController
    private var canvasViewController: WorkspaceCanvasHostController?
    private var installedController: NSViewController?
    private var installedMode: InstalledMode?
    private var workspaceCancellable: AnyCancellable?
    private var notificationStoreCancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var notificationTasks: [Task<Void, Never>] = []
    private var config: GhosttyConfig
    private var lastAppliedUsesHostLayerBackground = GhosttyApp.shared.usesHostLayerBackground
    private var deferredThemeRefresh: DeferredThemeRefresh?
    private var isTornDown = false

    init(configuration: WorkspaceContentNativeConfiguration) {
        let config = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "stateInit")
        let context = WorkspaceContentPresentationContext(
            configuration: configuration,
            appearance: PanelAppearance.fromConfig(config)
        )
        self.config = config
        self.context = context
        self.bonsplitViewController = BonsplitViewController(
            controller: configuration.workspace.bonsplitController,
            content: { [weak context] tab, paneID in
                guard let context, context.splitContentActive else {
                    return WorkspaceInactivePaneViewController()
                }
                let controller = WorkspaceBonsplitContentController(
                    context: context,
                    tab: tab,
                    paneID: paneID
                )
                context.register(controller)
                return controller
            },
            emptyPane: { [weak context] paneID in
                guard let context, context.splitContentActive else {
                    return WorkspaceInactivePaneViewController()
                }
                return WorkspaceEmptyPaneViewController(
                    workspace: context.configuration.workspace,
                    paneID: paneID
                )
            }
        )
        super.init(nibName: nil, bundle: nil)
        startObserving()
        configureFileDrop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root
        updateAgentHibernationPresentationVisibility()
        syncBonsplitNotificationBadges()
        refreshGhosttyAppearanceConfig(reason: "onAppear")
        refreshPresentation()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateAgentHibernationPresentationVisibility()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        context.configuration.workspace.setAgentHibernationAutoResumePresentationVisible(false)
    }

    func update(configuration: WorkspaceContentNativeConfiguration) {
        precondition(
            configuration.workspace === context.configuration.workspace,
            "Workspace content controller cannot change workspaces"
        )
        precondition(
            configuration.notificationStore === context.configuration.notificationStore,
            "Workspace content controller cannot change notification stores"
        )
        let wasVisible = context.configuration.isWorkspaceVisible
        context.configuration = configuration
        if isTornDown {
            isTornDown = false
            startObserving()
        }
        configureFileDrop()
        updateAgentHibernationPresentationVisibility()
        if !wasVisible, configuration.isWorkspaceVisible {
            flushDeferredThemeRefreshIfNeeded()
        }
        refreshPresentation()
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        context.configuration.workspace.setAgentHibernationAutoResumePresentationVisible(false)
        workspaceCancellable?.cancel()
        workspaceCancellable = nil
        notificationStoreCancellable?.cancel()
        notificationStoreCancellable = nil
        refreshTask?.cancel()
        refreshTask = nil
        notificationTasks.forEach { $0.cancel() }
        notificationTasks.removeAll(keepingCapacity: false)
        context.teardownSplitContent()
        context.splitContentActive = false
        bonsplitViewController.reloadContent()
        canvasViewController?.teardown()
        canvasViewController = nil
        installedController?.view.removeFromSuperview()
        installedController?.removeFromParent()
        installedController = nil
        installedMode = nil
    }

    private func startObserving() {
        let workspace = context.configuration.workspace
        workspaceCancellable?.cancel()
        workspaceCancellable = workspace.objectWillChange.sink { [weak self] in
            self?.scheduleRefresh()
        }
        let store = context.configuration.notificationStore
        notificationStoreCancellable?.cancel()
        notificationStoreCancellable = store.objectWillChange.sink { [weak self] in
            self?.scheduleRefresh()
        }

        notificationTasks.forEach { $0.cancel() }
        notificationTasks = [
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .ghosttyConfigDidReload) {
                    guard !Task.isCancelled, let self else { return }
                    self.refreshGhosttyAppearanceConfig(reason: "ghosttyConfigDidReload")
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: PaneChromeSettings.didChangeNotification
                ) {
                    guard !Task.isCancelled, let self else { return }
                    self.context.configuration.workspace.applyGhosttyChrome(
                        from: self.config,
                        reason: "paneChromeSettingsDidChange"
                    )
                    self.refreshPresentation()
                }
            },
            Task { @MainActor [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: .ghosttyDefaultBackgroundDidChange
                ) {
                    guard !Task.isCancelled, let self else { return }
                    self.handleDefaultBackgroundChange(notification)
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: .systemAppearanceDidChange
                ) {
                    guard !Task.isCancelled, let self else { return }
                    self.refreshGhosttyAppearanceConfig(reason: "effectiveAppearanceChanged")
                }
            },
        ]
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, !self.isTornDown else { return }
            self.refreshTask = nil
            self.updateAgentHibernationPresentationVisibility()
            self.syncBonsplitNotificationBadges()
            self.configureFileDrop()
            self.refreshPresentation()
        }
    }

    private func configureFileDrop() {
        let workspace = context.configuration.workspace
        workspace.bonsplitController.isInteractive = context.configuration.isWorkspaceInputActive
        workspace.bonsplitController.onFileDrop = { [weak workspace] urls, paneID in
            guard let workspace,
                  let tabID = workspace.bonsplitController.selectedTab(inPane: paneID)?.id,
                  let panelID = workspace.panelIdFromSurfaceId(tabID),
                  let panel = workspace.terminalInputTarget(forPanelID: panelID)?.panel else {
                return false
            }
            return panel.hostedView.handleDroppedURLs(urls)
        }
    }

    private func refreshPresentation() {
        guard isViewLoaded, !isTornDown else { return }
        context.appearance = PanelAppearance.fromConfig(config)
        view.layer?.backgroundColor = context.appearance.contentBackgroundColor.cgColor
        if context.configuration.workspace.layoutMode == .canvas {
            showCanvas()
        } else {
            showSplitTree()
        }
    }

    private func showSplitTree() {
        if installedMode != .split {
            canvasViewController?.teardown()
            canvasViewController = nil
            removeInstalledController()
            context.splitContentActive = true
            bonsplitViewController.reloadContent()
            install(bonsplitViewController)
            installedMode = .split
        }
        context.splitContentActive = true
        bonsplitViewController.refreshContent()
    }

    private func showCanvas() {
        if installedMode != .canvas {
            context.teardownSplitContent()
            context.splitContentActive = false
            bonsplitViewController.reloadContent()
            removeInstalledController()
            let controller = WorkspaceCanvasHostController(configuration: canvasConfiguration)
            canvasViewController = controller
            install(controller)
            installedMode = .canvas
        } else {
            canvasViewController?.update(configuration: canvasConfiguration)
        }
    }

    private var canvasConfiguration: WorkspaceCanvasHostConfiguration {
        let configuration = context.configuration
        return WorkspaceCanvasHostConfiguration(
            workspace: configuration.workspace,
            isWorkspaceVisible: configuration.isWorkspaceVisible,
            isWorkspaceInputActive: configuration.isWorkspaceInputActive,
            portalPriority: configuration.workspacePortalPriority,
            appearance: context.appearance,
            windowAppearance: configuration.windowAppearance,
            settingsRuntime: configuration.settingsRuntime,
            sessionContentWidthPresentation: configuration.sessionContentWidthPresentation
        )
    }

    private func install(_ controller: NSViewController) {
        addChild(controller)
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        installedController = controller
    }

    private func removeInstalledController() {
        installedController?.view.removeFromSuperview()
        installedController?.removeFromParent()
        installedController = nil
    }

    private func syncBonsplitNotificationBadges() {
        let workspace = context.configuration.workspace
        let store = context.configuration.notificationStore
        let manualUnread = workspace.manualUnreadPanelIds
        let restoredUnread = workspace.restoredUnreadPanelIds
        let isWorkspaceManuallyUnread = store.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelID = workspace.representativePanelIdForWorkspaceManualUnread()

        for paneID in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneID) {
                let panelID = workspace.panelIdFromSurfaceId(tab.id)
                let expectedKind = panelID.flatMap { workspace.panelKind(panelId: $0) }
                let expectedPinned = panelID.map { workspace.isPanelPinned($0) } ?? false
                let shouldShow = panelID.map {
                    Workspace.shouldShowUnreadIndicator(
                        hasUnreadNotification: store.hasVisibleNotificationIndicator(
                            forTabId: workspace.id,
                            surfaceId: $0
                        ),
                        hasPanelUnreadIndicator: manualUnread.contains($0)
                            || restoredUnread.contains($0),
                        isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                        isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelID == $0
                    )
                } ?? false
                let kindUpdate: String?? = expectedKind.map { .some($0) }
                if tab.showsNotificationBadge != shouldShow
                    || tab.isPinned != expectedPinned
                    || (expectedKind != nil && tab.kind != expectedKind) {
                    workspace.bonsplitController.updateTab(
                        tab.id,
                        kind: kindUpdate,
                        showsNotificationBadge: shouldShow,
                        isPinned: expectedPinned
                    )
                }
            }
        }
    }

    private func updateAgentHibernationPresentationVisibility() {
        let configuration = context.configuration
        configuration.workspace.setAgentHibernationAutoResumePresentationVisible(
            configuration.isWorkspaceVisible && configuration.isWorkspaceInputActive
        )
    }

    private func handleDefaultBackgroundChange(_ notification: Notification) {
        let payloadHex = (
            notification.userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor
        )?.hexString() ?? "nil"
        let foregroundHex = (
            notification.userInfo?[GhosttyNotificationKey.foregroundColor] as? NSColor
        )?.hexString() ?? "nil"
        let eventID = (
            notification.userInfo?[GhosttyNotificationKey.backgroundEventId] as? NSNumber
        )?.uint64Value
        let source = notification.userInfo?[GhosttyNotificationKey.backgroundSource] as? String
            ?? "nil"
        let workspace = context.configuration.workspace
        logTheme(
            "theme notification workspace=\(workspace.id.uuidString) event=\(eventID.map(String.init) ?? "nil") source=\(source) payload=\(payloadHex) payloadFg=\(foregroundHex) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appFg=\(GhosttyApp.shared.defaultForegroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
        )
        refreshGhosttyAppearanceConfig(
            reason: "ghosttyDefaultBackgroundDidChange",
            backgroundEventId: eventID,
            backgroundSource: source,
            notificationPayloadHex: payloadHex
        )
    }

    private func flushDeferredThemeRefreshIfNeeded() {
        guard context.configuration.isWorkspaceVisible,
              let deferredThemeRefresh else { return }
        self.deferredThemeRefresh = nil
        refreshGhosttyAppearanceConfig(
            reason: deferredThemeRefresh.reason,
            backgroundOverride: deferredThemeRefresh.backgroundOverride,
            backgroundEventId: deferredThemeRefresh.backgroundEventId,
            backgroundSource: deferredThemeRefresh.backgroundSource,
            notificationPayloadHex: deferredThemeRefresh.notificationPayloadHex,
            forceInitialApply: deferredThemeRefresh.forceInitialApply
        )
    }

    private func refreshGhosttyAppearanceConfig(
        reason: String,
        backgroundOverride: NSColor? = nil,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil,
        forceInitialApply: Bool = false
    ) {
        guard context.configuration.isWorkspaceVisible else {
            let existing = deferredThemeRefresh
            deferredThemeRefresh = DeferredThemeRefresh(
                reason: reason,
                backgroundOverride: backgroundOverride,
                backgroundEventId: backgroundEventId,
                backgroundSource: backgroundSource,
                notificationPayloadHex: notificationPayloadHex,
                forceInitialApply: forceInitialApply
                    || reason == "onAppear"
                    || existing?.forceInitialApply == true
            )
            return
        }
        deferredThemeRefresh = nil

        let workspace = context.configuration.workspace
        let previousSignature = WorkspaceContentView.ghosttyAppearanceSignature(
            config,
            usesHostLayerBackground: lastAppliedUsesHostLayerBackground
        )
        let previousBackgroundHex = config.backgroundColor.hexString()
        let next = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            reason: reason,
            backgroundOverride: backgroundOverride
        )
        let nextUsesHostLayerBackground = GhosttyApp.shared.usesHostLayerBackground
        let nextSignature = WorkspaceContentView.ghosttyAppearanceSignature(
            next,
            usesHostLayerBackground: nextUsesHostLayerBackground
        )
        let eventLabel = backgroundEventId.map(String.init) ?? "nil"
        let sourceLabel = backgroundSource ?? "nil"
        let payloadLabel = notificationPayloadHex ?? "nil"
        let configChanged = previousSignature != nextSignature
        let backgroundChanged = previousBackgroundHex != next.backgroundColor.hexString()
        let opacityChanged = abs(config.backgroundOpacity - next.backgroundOpacity) > 0.0001
        let blurChanged = config.backgroundBlur != next.backgroundBlur
        let shouldForceInitialApply = forceInitialApply || reason == "onAppear"
        let shouldRequestTitlebarRefresh = backgroundChanged
            || opacityChanged
            || blurChanged
            || shouldForceInitialApply
        let shouldApplyChrome = configChanged || shouldForceInitialApply
        let shouldRefreshWindowBackground = backgroundChanged
            || opacityChanged
            || blurChanged
            || shouldForceInitialApply
        if !shouldApplyChrome
            && !shouldRefreshWindowBackground
            && !shouldRequestTitlebarRefresh {
            logTheme(
                "theme refresh skip workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel)"
            )
            return
        }
        logTheme(
            "theme refresh begin workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousBg=\(previousBackgroundHex) nextBg=\(next.backgroundColor.hexString()) overrideBg=\(backgroundOverride?.hexString() ?? "nil")"
        )
        if configChanged {
            config = next
            context.appearance = PanelAppearance.fromConfig(next)
        }
        if shouldApplyChrome {
            lastAppliedUsesHostLayerBackground = nextUsesHostLayerBackground
        }
        if shouldRequestTitlebarRefresh {
            context.configuration.onThemeRefreshRequest?(
                reason,
                backgroundEventId,
                backgroundSource,
                notificationPayloadHex
            )
        }
        if shouldApplyChrome {
            let chromeReason =
                "refreshGhosttyAppearanceConfig:reason=\(reason):event=\(eventLabel):source=\(sourceLabel):payload=\(payloadLabel)"
            workspace.applyGhosttyChrome(from: next, reason: chromeReason)
        }
        if shouldRefreshWindowBackground {
            workspace.focusedTerminalInputTarget()?.panel.applyWindowBackgroundIfActive()
        }
        refreshPresentation()
        logTheme(
            "theme refresh end workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) chromeBg=\(workspace.bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil")"
        )
    }

    private func logTheme(_ message: String) {
        guard GhosttyApp.shared.backgroundLogEnabled else { return }
        GhosttyApp.shared.logBackground(message)
    }
}

@MainActor
private final class WorkspaceBonsplitContentController: NSViewController,
    BonsplitContentUpdating,
    BonsplitPaneDropZoneReceiving
{
    private enum InstalledKind: Equatable {
        case panel(UUID)
        case remote(ObjectIdentifier)
        case empty
    }

    private let context: WorkspaceContentPresentationContext
    private var tab: Bonsplit.Tab
    private var paneID: PaneID
    private var paneDropZone: DropZone?
    private var installedController: NSViewController?
    private var installedKind: InstalledKind?
    private var isTornDown = false

    init(
        context: WorkspaceContentPresentationContext,
        tab: Bonsplit.Tab,
        paneID: PaneID
    ) {
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
        view = NSView()
        render()
    }

    func updateBonsplitContent(tab: Bonsplit.Tab, pane: PaneID) {
        self.tab = tab
        paneID = pane
        render()
    }

    func bonsplitPaneDropZoneDidChange(_ zone: DropZone?) {
        paneDropZone = zone
        render()
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        teardownInstalledController()
    }

    private func render() {
        guard isViewLoaded, !isTornDown else { return }
        let workspace = context.configuration.workspace
        WorkspaceContentView.debugPanelLookup(tab: tab, workspace: workspace)
        guard let panel = workspace.panel(for: tab.id) else {
            installEmptyIfNeeded()
            return
        }

        if let mirror = workspace.remoteTmuxWindowMirror(forPanelId: panel.id) {
            installOrUpdateRemote(mirror, panel: panel)
        } else {
            installOrUpdatePanel(panel)
        }
    }

    private func installOrUpdatePanel(_ panel: any Panel) {
        let configuration = panelConfiguration(panel)
        if installedKind == .panel(panel.id),
           let controller = installedController as? PanelContentViewController {
            controller.update(configuration: configuration)
            return
        }
        let controller = PanelContentViewController(configuration: configuration)
        install(controller, kind: .panel(panel.id))
    }

    private func installOrUpdateRemote(
        _ mirror: RemoteTmuxWindowMirror,
        panel: any Panel
    ) {
        let configuration = context.configuration
        let workspace = configuration.workspace
        let paneID = paneID
        let isFocusedPanel = configuration.isWorkspaceInputActive
            && workspace.focusedPanelId == panel.id
        let isFocused = isFocusedPanel && !configuration.rightSidebarOwnsInputFocus
        let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneID)
        let isSelected = selectedTab?.id == tab.id
        let isVisible = WorkspaceContentView.panelVisibleInUI(
            isWorkspaceVisible: configuration.isWorkspaceVisible,
            paneHasSelectedTab: selectedTab != nil,
            isSelectedInPane: isSelected,
            isFocused: isFocusedPanel
        )
        let unreadSurfaceIDs = Set(
            mirror.surfaceIDsInLayoutOrder.lazy.filter {
                configuration.notificationStore.hasVisibleNotificationIndicator(
                    forTabId: workspace.id,
                    surfaceId: $0
                )
            }
        )
        let kind = InstalledKind.remote(ObjectIdentifier(mirror))
        if installedKind == kind,
           let controller = installedController as? RemoteTmuxWindowMirrorSplitViewController {
            controller.update(
                appearance: context.appearance,
                isOuterFocused: isFocused,
                isVisibleInUI: isVisible,
                portalPriority: configuration.workspacePortalPriority,
                onOuterFocus: { [weak workspace] in
                    workspace?.focusRemoteTmuxContainerPaneIfNeeded(paneID)
                },
                unreadSurfaceIDs: unreadSurfaceIDs
            )
            return
        }
        let controller = RemoteTmuxWindowMirrorSplitViewController(
            mirror: mirror,
            appearance: context.appearance,
            isOuterFocused: isFocused,
            isVisibleInUI: isVisible,
            portalPriority: configuration.workspacePortalPriority,
            onOuterFocus: { [weak workspace] in
                workspace?.focusRemoteTmuxContainerPaneIfNeeded(paneID)
            },
            unreadSurfaceIDs: unreadSurfaceIDs
        )
        install(controller, kind: kind)
    }

    private func panelConfiguration(_ panel: any Panel) -> PanelContentConfiguration {
        let configuration = context.configuration
        let workspace = configuration.workspace
        let paneID = paneID
        let isFocusedPanel = configuration.isWorkspaceInputActive
            && workspace.focusedPanelId == panel.id
        let isFocused = isFocusedPanel && !configuration.rightSidebarOwnsInputFocus
        let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneID)
        let isSelected = selectedTab?.id == tab.id
        let isVisible = WorkspaceContentView.panelVisibleInUI(
            isWorkspaceVisible: configuration.isWorkspaceVisible,
            paneHasSelectedTab: selectedTab != nil,
            isSelectedInPane: isSelected,
            isFocused: isFocusedPanel
        )
        let isWorkspaceManuallyUnread = configuration.notificationStore.hasManualUnread(
            forTabId: workspace.id
        )
        let representative = workspace.representativePanelIdForWorkspaceManualUnread()
        let showsNotificationRing = Workspace.shouldShowUnreadIndicator(
            hasUnreadNotification: configuration.notificationStore.hasVisibleNotificationIndicator(
                forTabId: workspace.id,
                surfaceId: panel.id
            ),
            hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panel.id)
                || workspace.restoredUnreadPanelIds.contains(panel.id),
            isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
            isWorkspaceManualUnreadRepresentative: representative == panel.id
        )
        var result = PanelContentConfiguration(
            panel: panel,
            workspaceID: workspace.id,
            paneID: paneID,
            isFocused: isFocused,
            isSelectedInPane: isSelected,
            isVisibleInUI: isVisible,
            allowsPointerInput: configuration.isWorkspaceInputActive
                && configuration.isWorkspaceVisible
                && isSelected,
            pointerEntryEventFilter: nil,
            portalPriority: configuration.workspacePortalPriority,
            isSplit: workspace.bonsplitController.allPaneIds.count > 1
                || workspace.panels.count > 1,
            appearance: context.appearance,
            windowAppearance: configuration.windowAppearance,
            customSidebarTabManager: workspace.owningTabManager,
            customSidebarUnread: configuration.notificationStore.sidebarUnread,
            hasUnreadNotification: showsNotificationRing
                && !TmuxOverlayExperimentSettings.target().usesWorkspacePaneOverlay,
            terminalAgentContext: WorkspaceContentView.terminalAgentContext(
                panel: panel,
                workspace: workspace
            ),
            paneOwnershipOverride: nil,
            terminalPaneOwnershipResolver: { [weak workspace, weak panel] in
                guard let workspace,
                      let panel,
                      let livePanel = workspace.panels[panel.id],
                      livePanel === panel,
                      workspace.paneId(forPanelId: panel.id)?.id == paneID.id,
                      let tabID = workspace.surfaceIdFromPanelId(panel.id) else {
                    return false
                }
                return workspace.bonsplitController.selectedTab(inPane: paneID)?.id == tabID
            },
            paneDropZone: paneDropZone,
            onFocus: { [weak workspace, weak panel] in
                guard configuration.isWorkspaceInputActive,
                      let workspace,
                      let panel,
                      workspace.panels[panel.id] != nil else { return }
                workspace.focusPanel(
                    panel.id,
                    trigger: .terminalFirstResponder,
                    focusTransactionId: workspace.activeFocusTransactionId
                )
            },
            onRequestPanelFocus: { [weak workspace, weak panel] in
                guard configuration.isWorkspaceInputActive,
                      let workspace,
                      let panel,
                      workspace.panels[panel.id] != nil else { return }
                AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                    workspaceId: workspace.id,
                    panelId: panel.id,
                    in: NSApp.keyWindow ?? NSApp.mainWindow
                )
                workspace.focusPanel(panel.id)
            },
            onResumeAgentHibernation: { [weak workspace, weak panel] in
                guard configuration.isWorkspaceInputActive,
                      let workspace,
                      let panel,
                      workspace.panels[panel.id] != nil else { return }
                workspace.resumeAgentHibernation(panelId: panel.id, focus: true)
            },
            onAutoResumeAgentHibernation: { [weak workspace, weak panel] in
                guard configuration.isWorkspaceInputActive,
                      let workspace,
                      let panel,
                      workspace.panels[panel.id] != nil else { return }
                workspace.resumeAgentHibernation(panelId: panel.id, focus: false)
            },
            onTriggerFlash: { [weak workspace, weak panel] in
                guard let workspace, let panel else { return }
                workspace.triggerDebugFlash(panelId: panel.id)
            }
        )
        result.settingsRuntime = configuration.settingsRuntime
        return result
    }

    private func installEmptyIfNeeded() {
        guard installedKind != .empty else { return }
        install(
            WorkspaceEmptyPaneViewController(
                workspace: context.configuration.workspace,
                paneID: paneID
            ),
            kind: .empty
        )
    }

    private func install(_ controller: NSViewController, kind: InstalledKind) {
        teardownInstalledController()
        addChild(controller)
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        installedController = controller
        installedKind = kind
    }

    private func teardownInstalledController() {
        if let controller = installedController as? PanelContentViewController {
            controller.teardown()
        } else if let controller = installedController as? RemoteTmuxWindowMirrorSplitViewController {
            controller.teardown()
        }
        installedController?.view.removeFromSuperview()
        installedController?.removeFromParent()
        installedController = nil
        installedKind = nil
    }
}

@MainActor
private final class WorkspaceInactivePaneViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }
}

@MainActor
private final class WorkspaceEmptyPaneViewController: NSViewController {
    private weak var workspace: Workspace?
    private let paneID: PaneID
    private let terminalButton = NSButton()
    private let browserButton = NSButton()
    private var shortcutObservationGeneration: UInt = 0

    init(workspace: Workspace, paneID: PaneID) {
        self.workspace = workspace
        self.paneID = paneID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = GhosttyBackgroundTheme.currentColor().cgColor

        let icon = NSImageView(
            image: NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)
                ?? NSImage()
        )
        icon.symbolConfiguration = .init(pointSize: 48, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: String(
            localized: "emptyPanel.title",
            defaultValue: "Empty Panel"
        ))
        title.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor

        configureButton(
            terminalButton,
            systemImage: "terminal.fill",
            action: #selector(createTerminal)
        )
        configureButton(browserButton, systemImage: "globe", action: #selector(createBrowser))
        let buttons = NSStackView(views: [terminalButton, browserButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12

        let stack = NSStackView(views: [icon, title, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
        ])
        view = root
#if DEBUG
        DebugUIEventCounters.emptyPanelAppearCount += 1
#endif
        observeShortcuts()
    }

    private func configureButton(
        _ button: NSButton,
        systemImage: String,
        action: Selector
    ) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
    }

    private func observeShortcuts() {
        shortcutObservationGeneration &+= 1
        let generation = shortcutObservationGeneration
        withObservationTracking {
            _ = KeyboardShortcutSettingsObserver.shared.revision
            updateButtonTitles()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.shortcutObservationGeneration == generation else { return }
                self.observeShortcuts()
            }
        }
    }

    private func updateButtonTitles() {
        let terminalTitle = String(
            localized: "commandPalette.kind.terminal",
            defaultValue: "Terminal"
        )
        let browserTitle = String(
            localized: "commandPalette.kind.browser",
            defaultValue: "Browser"
        )
        terminalButton.title = "\(terminalTitle)  \(KeyboardShortcutSettings.shortcut(for: .newSurface).displayString)"
        browserButton.title = "\(browserTitle)  \(KeyboardShortcutSettings.shortcut(for: .openBrowser).displayString)"
        terminalButton.setAccessibilityLabel(terminalTitle)
        browserButton.setAccessibilityLabel(browserTitle)
    }

    @objc private func createTerminal() {
        guard let workspace else { return }
#if DEBUG
        cmuxDebugLog("emptyPane.newTerminal pane=\(paneID.id.uuidString.prefix(5))")
#endif
        workspace.bonsplitController.focusPane(paneID)
        _ = workspace.newTerminalSurface(inPane: paneID, inheritWorkingDirectoryFallback: true)
    }

    @objc private func createBrowser() {
        guard let workspace else { return }
#if DEBUG
        cmuxDebugLog("emptyPane.newBrowser pane=\(paneID.id.uuidString.prefix(5))")
#endif
        workspace.bonsplitController.focusPane(paneID)
        _ = workspace.newBrowserSurface(inPane: paneID)
    }
}

/// Namespace for workspace rendering policies shared with window overlays and tests.
@MainActor
enum WorkspaceContentView {
    nonisolated static func panelVisibleInUI(
        isWorkspaceVisible: Bool,
        paneHasSelectedTab: Bool,
        isSelectedInPane: Bool,
        isFocused: Bool
    ) -> Bool {
        WorkspacePanelVisibilityPolicy.panelVisibleInUI(
            isWorkspaceVisible: isWorkspaceVisible,
            paneHasSelectedTab: paneHasSelectedTab,
            isSelectedInPane: isSelectedInPane,
            isFocused: isFocused
        )
    }

    private static let tmuxPaneOverlayGeometry = TmuxPaneOverlayGeometry(
        topChromeHeight: MinimalModeChromeMetrics.titlebarHeight
    )

    private static func tmuxWorkspacePaneRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?,
        includeContainerOffset: Bool
    ) -> [CGRect] {
        guard let layoutSnapshot else { return [] }
        let geometry = tmuxPaneOverlayGeometry
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelID = workspace.representativePanelIdForWorkspaceManualUnread()

        return layoutSnapshot.panes.compactMap { pane in
            guard let selectedTabID = pane.selectedTabId,
                  let tabUUID = UUID(uuidString: selectedTabID),
                  let panelID = workspace.panelIdFromSurfaceId(TabID(uuid: tabUUID)) else {
                return nil
            }
            let shouldShowUnread = Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                    forTabId: workspace.id,
                    surfaceId: panelID
                ),
                hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panelID)
                    || workspace.restoredUnreadPanelIds.contains(panelID),
                isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelID == panelID
            )
            guard shouldShowUnread else { return nil }
            let paneRect = pane.frame.cgRect
            if includeContainerOffset {
                return geometry.contentRect(paneRect.offsetBy(
                    dx: 0,
                    dy: -CGFloat(layoutSnapshot.containerFrame.y)
                ))
            }
            return geometry.contentRect(paneRect.offsetBy(
                dx: -CGFloat(layoutSnapshot.containerFrame.x),
                dy: -CGFloat(layoutSnapshot.containerFrame.y)
            ))
        }
    }

    static func tmuxWorkspacePaneOverlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        tmuxPaneOverlayGeometry.overlayRect(layoutSnapshot: layoutSnapshot, paneId: paneId)
    }

    static func tmuxWorkspacePaneWindowOverlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        tmuxPaneOverlayGeometry.windowOverlayRect(layoutSnapshot: layoutSnapshot, paneId: paneId)
    }

    static func effectiveTmuxLayoutSnapshot(
        cachedSnapshot: LayoutSnapshot?,
        liveSnapshot: LayoutSnapshot?
    ) -> LayoutSnapshot? {
        tmuxPaneOverlayGeometry.effectiveSnapshot(
            cachedSnapshot: cachedSnapshot,
            liveSnapshot: liveSnapshot
        )
    }

    static func tmuxWorkspacePaneUnreadRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?
    ) -> [CGRect] {
        tmuxWorkspacePaneRects(
            workspace: workspace,
            notificationStore: notificationStore,
            layoutSnapshot: layoutSnapshot,
            includeContainerOffset: false
        )
    }

    static func tmuxWorkspacePaneWindowUnreadRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?
    ) -> [CGRect] {
        tmuxWorkspacePaneRects(
            workspace: workspace,
            notificationStore: notificationStore,
            layoutSnapshot: layoutSnapshot,
            includeContainerOffset: true
        )
    }

    static func terminalAgentContext(panel: any Panel, workspace: Workspace) -> String {
        var parts: [String] = []
        if let terminalPanel = panel as? TerminalPanel {
            if let initialCommand = terminalPanel.surface.initialCommand {
                parts.append("initialCommand:\(initialCommand)")
            }
            if let tmuxStartCommand = terminalPanel.surface.tmuxStartCommand {
                parts.append("tmuxStartCommand:\(tmuxStartCommand)")
            }
            if let pendingLaunchCommand = terminalPanel.textBoxState.pendingLaunchCommand?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !pendingLaunchCommand.isEmpty {
                parts.append("textBoxPendingLaunchCommand:\(pendingLaunchCommand)")
            }
        }
        if let restoredAgent = workspace.restoredAgentSnapshotForContinuation(panelId: panel.id) {
            parts.append("restoredAgent:\(restoredAgent.kind.rawValue)")
        }
        if let agentPIDKeys = workspace.agentPIDKeysByPanelId[panel.id], !agentPIDKeys.isEmpty {
            for key in agentPIDKeys.sorted() {
                parts.append("agentPIDKey:\(key)")
            }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

#if DEBUG
    static func debugPanelLookup(tab: Bonsplit.Tab, workspace: Workspace) {
        guard workspace.panel(for: tab.id) == nil else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] PANEL NOT FOUND for tabId=\(tab.id) ws=\(workspace.id) panelCount=\(workspace.panels.count)\n"
        let logPath = "/tmp/cmux-panel-debug.log"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
        }
    }
#else
    static func debugPanelLookup(tab: Bonsplit.Tab, workspace: Workspace) {
        _ = tab
        _ = workspace
    }
#endif
}

#if DEBUG
@MainActor
enum DebugUIEventCounters {
    static var emptyPanelAppearCount: Int = 0

    static func resetEmptyPanelAppearCount() {
        emptyPanelAppearCount = 0
    }
}
#endif
