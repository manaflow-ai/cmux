import AppKit
import Bonsplit
import Combine
import CmuxAgentChat
import CmuxAppKitSupportUI
import CmuxBrowser
import CmuxCore
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxTerminal
import CmuxTerminalCore
import CmuxWorkspaces
import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class DockSplitStore: BonsplitDelegate, FilePreviewTabMetadataHost {
    private struct PanelSurfaceMapping {
        var primarySurfaceId: TabID
        var surfaceIds: Set<TabID>
    }

    private struct PendingTerminalTitleUpdate {
        let title: String
        weak var sourceSurface: TerminalSurface?
        let sourceTerminalLifecycleId: UUID
    }

    let workspaceId: UUID
    let bonsplitController: BonsplitController
    /// Pane ownership updated synchronously from Bonsplit lifecycle callbacks.
    @ObservationIgnored var ownedPaneIds: Set<UUID> = []

    /// Which Dock this store backs: `.workspace` (per-workspace, seeded from the
    /// project `.cmux/dock.json`) or `.global` (a per-window Dock seeded from
    /// the global `~/.config/cmux/dock.json`, owner id == window id). Drives
    /// config resolution and how cross-container moves resolve a reference window.
    let scope: DockScope

    private(set) var sourceLabel: String = ""
    private(set) var errorMessage: String?
    private(set) var trustRequest: DockTrustRequest?
    private(set) var isVisibleInUI: Bool = false
    /// Host views currently showing this Dock. Normally at most one (the owning
    /// window's right sidebar), but SwiftUI remounts can briefly overlap an old
    /// and new host, so visibility is the union rather than a single flag.
    private var visibleUIHostIds: Set<UUID> = []
    @ObservationIgnored let dockPortalReconcileState = DockPortalReconcileState()
    @ObservationIgnored let appLinkHandoffCoordinator = BrowserAppLinkHandoffCoordinator()
    @ObservationIgnored let appLinkPlacementPolicy = BrowserAppLinkPlacementPolicy()

    private let baseDirectoryProvider: () -> String?
    private let remoteBrowserSettingsProvider: () -> DockRemoteBrowserSettings
    private let browserAvailabilityProvider: () -> Bool
    @ObservationIgnored weak var notificationStore: TerminalNotificationStore?
    var panels: [UUID: any Panel] = [:]
    var surfaceIdToPanelId: [TabID: UUID] = [:]
    /// Dock-owned manual unread state. Unlike notification-derived unread state,
    /// this must survive session snapshots and live moves between split hosts.
    @ObservationIgnored var manualUnreadPanelIds: Set<UUID> = []
    /// Reverse index for O(1) panel-owned tab lookups and alias promotion.
    @ObservationIgnored private var panelSurfaceMappings: [UUID: PanelSurfaceMapping] = [:]
    private var lastTerminalFontSizeLineage: TerminalFontSizeLineage?
    weak var terminalFontSizeChangeCoordinator:
        WorkspaceTerminalFontSizeCoordinator?
    weak var terminalFontSizeChangeArbiter:
        WorkspaceTerminalFontSizeArbiter?
    weak var terminalFontSizeOwningWorkspace: Workspace?
    @ObservationIgnored private var activeTerminalFontSizeChangeInheritanceContext:
        TerminalFontSizeChangeInheritanceContext?
    var panelCancellables: [UUID: AnyCancellable] = [:]
    @ObservationIgnored private var pendingTerminalTitleUpdates:
        [UUID: PendingTerminalTitleUpdate] = [:]
    @ObservationIgnored private let terminalTitleUpdateCoalescer:
        NotificationBurstCoalescer
    @ObservationIgnored var detachedSurfaceTransfersByPanelId: [UUID: Workspace.DetachedSurfaceTransfer] = [:]
    /// Focused presentation of Dock panels whose agent lifecycle needs input.
    @ObservationIgnored let agentNeedsInputAttention = SurfaceAttentionModel()
    @ObservationIgnored var restoredPanelTitleBoundariesByPanelId:
        [UUID: RestoredPanelTitleBoundary] = [:]
    /// Live agent runtime owned by Dock panels. The matching transfer snapshot
    /// is kept in sync so the state survives Dock-to-workspace moves.
    @ObservationIgnored var agentRuntimeByPanelId: [UUID: Workspace.DetachedAgentRuntimeState] = [:]
    @ObservationIgnored var restoredTerminalScrollbackByPanelId: [UUID: String] = [:]
    @ObservationIgnored let terminalStartupRestoreCoordinator: TerminalStartupRestoreCoordinator
    var restoredAgentLifecycle: RestoredAgentLifecycleCoordinator {
        terminalStartupRestoreCoordinator.lifecycle
    }
    @ObservationIgnored var surfaceResumeBindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
    /// Authoritative agent-hook identity for a Dock panel. The effective
    /// surface binding may temporarily become a process-detected tmux binding,
    /// but hook teardown must still address the managed agent generation.
    @ObservationIgnored var managedAgentResumeBindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
    @ObservationIgnored var invalidatedCachedTransferAgentSessionPanelIds: Set<UUID> = []
    @ObservationIgnored var replacedCachedTransferAgentSessionPanelIds: Set<UUID> = []
    var restoredResumeSessionWorkingDirectoriesByPanelId: [UUID: String] {
        get { restoredAgentLifecycle.resumeWorkingDirectoriesByPanelId }
        set { restoredAgentLifecycle.resumeWorkingDirectoriesByPanelId = newValue }
    }
    var hasLoadedConfiguration = false
    var configurationLoadTask: Task<Void, Never>?
    var configurationIdentityTask: Task<Void, Never>?
    var configurationLoadGeneration = 0
    var configurationIdentityGeneration = 0
    var configurationLoadRootDirectory: String?
    private var configurationSeedSuppressionGeneration: Int?
    private var activeConfigURL: URL?
    private var rootDirectoryOverride: String?
    private var resolvedBaseDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    /// Last loaded resolved config identity.
    private var lastLoadedConfigIdentity: DockConfigIdentity?
    @ObservationIgnored var hasAppliedConfigurationSeed = false
    /// True while a programmatic split (config seed, `newSplit`, cross-container
    /// transfer) is creating its own panel in the new pane, so the `didSplitPane`
    /// delegate skips the interactive auto-create / placeholder-repair path.
    /// Mirrors `Workspace.isProgrammaticSplit`.
    @ObservationIgnored var isProgrammaticDockSplit = false
    @ObservationIgnored var forceCloseDockTabIds: Set<TabID> = []
    @ObservationIgnored var pendingCloseConfirmDockTabIds: Set<TabID> = []
    @ObservationIgnored var tabCloseButtonCloseDockTabIds: Set<TabID> = []
    @ObservationIgnored var closeHistoryEligibleDockTabIds: Set<TabID> = []
    @ObservationIgnored var pendingClosedPanelHistoryEntries:
        [TabID: ClosedPanelHistoryEntry] = [:]
    @ObservationIgnored var pendingClosedPaneHistoryEntries:
        [UUID: [ClosedPanelHistoryEntry]] = [:]
    @ObservationIgnored let closedItemHistoryStore: ClosedItemHistoryStore
    @ObservationIgnored var reactGrabTask: Task<Void, Never>?
    @ObservationIgnored var reactGrabTaskID: UUID?
    @ObservationIgnored var reactGrabTaskPanelId: UUID?
    @ObservationIgnored var terminalViewReattachCoalescingDepth = 0
    @ObservationIgnored var pendingTerminalViewReattachPanelIds: Set<UUID> = []
    @ObservationIgnored let focusHistoryNavigation: any FocusHistoryNavigating
    @ObservationIgnored let terminalWorkingDirectoryResolver: TerminalWorkingDirectoryResolver
    private let settings: any SettingsReading
    private let settingsCatalog = SettingCatalog()
    let agentSessionAutoResumeDefaults: UserDefaults

    /// Weak registry of every live Dock store. Lets control-surface routing
    /// resolve a Dock surface/pane by querying only the workspaces that actually
    /// have a Dock (their authoritative `containsPanel`/`containsPane`), instead
    /// of walking every window × workspace tab on each resolution. Entries drop
    /// automatically when a store deallocates; accessed on the main actor only.
    @MainActor private static let liveStoresTable = NSHashTable<DockSplitStore>.weakObjects()
    /// Weak, presentation-workspace-scoped ownership avoids app-wide Dock
    /// traversal for every remote terminal lifecycle callback.
    @MainActor private static var remoteTerminalStoresByPresentationWorkspaceID:
        [UUID: NSHashTable<DockSplitStore>] = [:]

    @MainActor static var liveStores: [DockSplitStore] { liveStoresTable.allObjects }

    @MainActor
    static func liveRemoteTerminalStores(
        presentationWorkspaceID: UUID
    ) -> [DockSplitStore] {
        guard let stores = remoteTerminalStoresByPresentationWorkspaceID[
            presentationWorkspaceID
        ] else {
            return []
        }
        let liveStores = stores.allObjects
        if liveStores.isEmpty {
            remoteTerminalStoresByPresentationWorkspaceID.removeValue(
                forKey: presentationWorkspaceID
            )
        }
        return liveStores
    }

    func setDetachedSurfaceTransfer(
        _ transfer: Workspace.DetachedSurfaceTransfer,
        forPanelID panelID: UUID
    ) {
        let previous = detachedSurfaceTransfersByPanelId.updateValue(
            transfer,
            forKey: panelID
        )
        let previousWorkspaceID = previous.flatMap(
            Self.remoteTerminalPresentationWorkspaceID
        )
        let currentWorkspaceID = Self.remoteTerminalPresentationWorkspaceID(
            transfer
        )
        guard previousWorkspaceID != currentWorkspaceID else { return }
        if let previousWorkspaceID,
           !hasRemoteTerminalTransfer(
               presentationWorkspaceID: previousWorkspaceID
           ) {
            Self.unregisterRemoteTerminalStore(
                self,
                presentationWorkspaceID: previousWorkspaceID
            )
        }
        if let currentWorkspaceID {
            Self.registerRemoteTerminalStore(
                self,
                presentationWorkspaceID: currentWorkspaceID
            )
        }
    }

    @discardableResult
    func removeDetachedSurfaceTransfer(
        forPanelID panelID: UUID
    ) -> Workspace.DetachedSurfaceTransfer? {
        guard let removed = detachedSurfaceTransfersByPanelId.removeValue(
            forKey: panelID
        ) else {
            return nil
        }
        if let workspaceID = Self.remoteTerminalPresentationWorkspaceID(removed),
           !hasRemoteTerminalTransfer(presentationWorkspaceID: workspaceID) {
            Self.unregisterRemoteTerminalStore(
                self,
                presentationWorkspaceID: workspaceID
            )
        }
        return removed
    }

    func removeAllDetachedSurfaceTransfers() {
        let workspaceIDs = Set(
            detachedSurfaceTransfersByPanelId.values.compactMap(
                Self.remoteTerminalPresentationWorkspaceID
            )
        )
        detachedSurfaceTransfersByPanelId.removeAll()
        for workspaceID in workspaceIDs {
            Self.unregisterRemoteTerminalStore(
                self,
                presentationWorkspaceID: workspaceID
            )
        }
    }

    private func hasRemoteTerminalTransfer(
        presentationWorkspaceID: UUID
    ) -> Bool {
        detachedSurfaceTransfersByPanelId.values.contains {
            Self.remoteTerminalPresentationWorkspaceID($0) ==
                presentationWorkspaceID
        }
    }

    private static func remoteTerminalPresentationWorkspaceID(
        _ transfer: Workspace.DetachedSurfaceTransfer
    ) -> UUID? {
        transfer.isRemoteTerminal ? transfer.sessionRestoreWorkspaceId : nil
    }

    private static func registerRemoteTerminalStore(
        _ store: DockSplitStore,
        presentationWorkspaceID: UUID
    ) {
        let stores: NSHashTable<DockSplitStore>
        if let existing = remoteTerminalStoresByPresentationWorkspaceID[
            presentationWorkspaceID
        ] {
            stores = existing
        } else {
            stores = .weakObjects()
            remoteTerminalStoresByPresentationWorkspaceID[
                presentationWorkspaceID
            ] = stores
        }
        stores.add(store)
    }

    private static func unregisterRemoteTerminalStore(
        _ store: DockSplitStore,
        presentationWorkspaceID: UUID
    ) {
        guard let stores = remoteTerminalStoresByPresentationWorkspaceID[
            presentationWorkspaceID
        ] else {
            return
        }
        stores.remove(store)
        if stores.allObjects.isEmpty {
            remoteTerminalStoresByPresentationWorkspaceID.removeValue(
                forKey: presentationWorkspaceID
            )
        }
    }

    init(
        workspaceId: UUID,
        scope: DockScope = .workspace,
        baseDirectoryProvider: @escaping () -> String?,
        remoteBrowserSettingsProvider: @escaping () -> DockRemoteBrowserSettings = { .local },
        browserAvailabilityProvider: @escaping () -> Bool = { BrowserAvailabilitySettings.isEnabled() },
        terminalTitleUpdateCoalescer: NotificationBurstCoalescer? = nil,
        tabDragTransferRegistry: TabDragTransferRegistry? = nil,
        settings: any SettingsReading = UserDefaultsSettingsClient(defaults: .standard),
        agentSessionAutoResumeDefaults: UserDefaults = .standard,
        agentChatResumeIntentRecorder: any AgentChatResumeIntentRecording = AgentChatTranscriptResumeIntentRecorder(),
        terminalWorkingDirectoryResolver: TerminalWorkingDirectoryResolver = TerminalWorkingDirectoryResolver(),
        closedItemHistoryStore: ClosedItemHistoryStore? = nil
    ) {
        let tabDragTransferRegistry = tabDragTransferRegistry ?? TabDragTransferRegistry()
        self.workspaceId = workspaceId
        self.scope = scope
        self.baseDirectoryProvider = baseDirectoryProvider
        self.remoteBrowserSettingsProvider = remoteBrowserSettingsProvider
        self.browserAvailabilityProvider = browserAvailabilityProvider
        self.terminalTitleUpdateCoalescer =
            terminalTitleUpdateCoalescer ?? NotificationBurstCoalescer()
        self.settings = settings
        self.agentSessionAutoResumeDefaults = agentSessionAutoResumeDefaults
        self.terminalStartupRestoreCoordinator = TerminalStartupRestoreCoordinator(
            workspaceID: workspaceId,
            lifecycle: RestoredAgentLifecycleCoordinator(),
            resumeIntentRecorder: agentChatResumeIntentRecorder
        )
        self.terminalWorkingDirectoryResolver = terminalWorkingDirectoryResolver
        self.closedItemHistoryStore =
            closedItemHistoryStore
            ?? ClosedItemHistoryStore(
                capacity: 100,
                loadPersisted: false
            )
        let focusHistoryScopeKey = SettingCatalog().app.focusHistoryIncludesPanesAndTabs
        self.focusHistoryNavigation = FocusHistoryModel(navigationScope: {
            settings.value(for: focusHistoryScopeKey) ? .panesAndTabs : .workspacesOnly
        })
        self.bonsplitController = BonsplitController(
            configuration: Self.makeConfiguration(),
            tabDragTransferRegistry: tabDragTransferRegistry
        )
        self.sourceLabel = String(localized: "dock.source.title", defaultValue: "Dock")
        self.bonsplitController.delegate = self
        self.bonsplitController.contextMenuShortcuts = Workspace.buildContextMenuShortcuts()
        self.bonsplitController.onTabCloseRequest = { [weak self] tabId, _, source in
            guard source == .closeButton else { return }
            self?.tabCloseButtonCloseDockTabIds.insert(tabId)
        }
        self.bonsplitController.onTabZoomToggleRequest = { [weak self] _, paneId in
            self?.toggleDockPaneZoom(inPane: paneId) ?? false
        }
        // Accept tabs dragged in from the main split area or another Dock. A
        // drag that started in a different controller is "external" to this one,
        // so Bonsplit routes it here; the live panel is moved (not copied).
        self.bonsplitController.onExternalTabDrop = { [weak self] request in
            guard let self else { return false }
            if let handled = self.performRegisteredPaneTransferDrop(request) {
                return handled
            }
            return AppDelegate.shared?.moveSurfaceIntoDock(
                sourceTabId: request.tabId.uuid,
                destinationDock: self,
                destination: request.destination
            ) ?? false
        }
        // Offer the same tab "Move to…" destinations as the main area (existing
        // workspaces + New Workspace), so a Dock tab can leave the Dock via its
        // context menu, not only by dragging.
        self.bonsplitController.tabContextMoveDestinationsProvider = { [weak self] tabId, _ in
            self?.dockTabMoveDestinations(for: tabId) ?? []
        }
        // Drop the controller's default welcome tab so the root pane starts
        // empty and renders the in-app create affordance until config seeds it.
        for tabId in bonsplitController.allTabIds {
            _ = bonsplitController.closeTab(tabId)
        }
        ownedPaneIds = Set(bonsplitController.allPaneIds.map(\.id))
        focusHistoryNavigation.attach(host: self)
        Self.liveStoresTable.add(self)
    }

    var focusHistoryIncludesPanesAndTabs: Bool {
        settings.value(for: settingsCatalog.app.focusHistoryIncludesPanesAndTabs)
    }

    // MARK: - Lookups

    func currentRemoteBrowserSettings() -> DockRemoteBrowserSettings { remoteBrowserSettingsProvider() }
    func isBrowserAvailable() -> Bool { browserAvailabilityProvider() }

    func panel(for tabId: TabID) -> (any Panel)? {
        guard let panelId = surfaceIdToPanelId[tabId] else { return nil }
        return panels[panelId]
    }

    func forEachPanel(_ body: (UUID, any Panel) -> Void) {
        for (panelId, panel) in panels { body(panelId, panel) }
    }

    func browserPanel(for panelId: UUID) -> BrowserPanel? {
        panels[panelId] as? BrowserPanel
    }

    /// Binds a Dock tab to its panel and makes that tab the authoritative reverse lookup.
    func bindSurface(_ surfaceId: TabID, toPanelId panelId: UUID) {
        if let previousPanelId = surfaceIdToPanelId[surfaceId],
           previousPanelId != panelId {
            removeSurfaceMapping(forSurfaceId: surfaceId)
        }
        surfaceIdToPanelId[surfaceId] = panelId
        if var mapping = panelSurfaceMappings[panelId] {
            mapping.primarySurfaceId = surfaceId
            mapping.surfaceIds.insert(surfaceId)
            panelSurfaceMappings[panelId] = mapping
        } else {
            panelSurfaceMappings[panelId] = PanelSurfaceMapping(
                primarySurfaceId: surfaceId,
                surfaceIds: [surfaceId]
            )
        }
    }

    /// Removes one Dock tab mapping, promoting a remaining alias when necessary.
    func removeSurfaceMapping(forSurfaceId surfaceId: TabID) {
        guard let panelId = surfaceIdToPanelId.removeValue(forKey: surfaceId),
              var mapping = panelSurfaceMappings[panelId] else {
            return
        }
        mapping.surfaceIds.remove(surfaceId)
        guard let replacementSurfaceId = mapping.surfaceIds.first else {
            panelSurfaceMappings.removeValue(forKey: panelId)
            return
        }
        if mapping.primarySurfaceId == surfaceId {
            mapping.primarySurfaceId = replacementSurfaceId
        }
        panelSurfaceMappings[panelId] = mapping
    }

    /// Removes every Dock tab mapping for a panel.
    func removeSurfaceMappings(forPanelId panelId: UUID) {
        guard let mapping = panelSurfaceMappings.removeValue(forKey: panelId) else {
            return
        }
        for surfaceId in mapping.surfaceIds {
            surfaceIdToPanelId.removeValue(forKey: surfaceId)
        }
    }

    /// Clears both directions of the Dock tab-to-panel registry.
    func removeAllSurfaceMappings() {
        surfaceIdToPanelId.removeAll()
        panelSurfaceMappings.removeAll()
    }

    func surfaceId(forPanelId panelId: UUID) -> TabID? {
        panelSurfaceMappings[panelId]?.primarySurfaceId
    }

    func paneId(forPanelId panelId: UUID) -> PaneID? {
        guard let tabId = surfaceId(forPanelId: panelId) else { return nil }
        return bonsplitController.paneId(containing: tabId)
    }

    // MARK: - Lifecycle

    /// Drives Dock activation from the right sidebar: loads config on first
    /// visible activation and toggles panel UI visibility.
    func setActive(isVisible: Bool, mode: RightSidebarMode, visibilityHostId: UUID? = nil) {
        let shouldBeVisible = isVisible && mode == .dock
        if shouldBeVisible {
            if hasLoadedConfiguration {
                reloadIfBaseDirectoryChanged()
            } else {
                ensureLoaded()
            }
        }
        if let visibilityHostId {
            setVisibleInUI(shouldBeVisible, hostId: visibilityHostId)
        } else {
            setVisibleInUI(shouldBeVisible)
        }
    }

    func setRootDirectory(_ directory: String?) {
        rootDirectoryOverride = Self.normalizedBaseDirectory(directory)
    }

    private func reloadIfBaseDirectoryChanged() {
        guard hasLoadedConfiguration else { return }
        let rootDirectory = currentBaseDirectory()
        if configurationLoadTask != nil, rootDirectory != configurationLoadRootDirectory { reload(); return }
        guard configurationLoadTask == nil else { return }
        configurationIdentityGeneration += 1
        let generation = configurationIdentityGeneration
        configurationIdentityTask?.cancel()
        let scope = scope
        configurationIdentityTask = Task.detached(priority: .utility) { [weak self] in
            let current = Self.configIdentity(scope: scope, rootDirectory: rootDirectory)
            guard !Task.isCancelled else { return }
            await self?.applyConfigurationIdentity(current, generation: generation)
        }
    }

    func setVisibleInUI(_ visible: Bool) {
        if !visible {
            visibleUIHostIds.removeAll()
        }
        guard isVisibleInUI != visible else { return }
        isVisibleInUI = visible
        applyFocusedDockSelection()
    }

    func setVisibleInUI(_ visible: Bool, hostId: UUID) {
        if visible {
            visibleUIHostIds.insert(hostId)
        } else {
            visibleUIHostIds.remove(hostId)
        }
        let anyHostVisible = !visibleUIHostIds.isEmpty
        guard isVisibleInUI != anyHostVisible else { return }
        isVisibleInUI = anyHostVisible
        applyFocusedDockSelection()
    }

    /// Tears down every Dock panel (closing terminals/browsers and their
    /// portals). Called from `Workspace.teardownAllPanels()` on workspace close.
    func closeAllPanels() {
        cancelConfigurationTasks()
        setVisibleInUI(false)
        removeAllPanels()
    }

    func ensureLoaded() {
        guard !hasLoadedConfiguration else { return }
        hasLoadedConfiguration = true
        startConfigurationLoad(replacingPanels: false)
    }

    // MARK: - In-app creation

    /// Applies the shared pane-zoom preference to a focused Dock tab request.
    private func applyNewTabZoomPolicy(inPane paneId: PaneID) {
        let zoomedPaneId = bonsplitController.zoomedPaneId
        let keepExpanded = settings.value(for: settingsCatalog.app.keepExpandedOnNewTab)
        guard zoomedPaneId != nil,
              !(keepExpanded && zoomedPaneId == paneId) else { return }
        _ = bonsplitController.clearPaneZoom()
        applyVisibilityToAllPanels()
    }

    /// Runs a Dock tab creation transactionally with the shared pane-zoom policy.
    private func withNewTabZoomPolicy<Result>(
        inPane paneId: PaneID,
        _ operation: () -> Result?
    ) -> Result? {
        let previousZoomedPaneId = bonsplitController.zoomedPaneId
        applyNewTabZoomPolicy(inPane: paneId)
        let result = operation()
        if result == nil,
           let previousZoomedPaneId,
           bonsplitController.zoomedPaneId == nil,
           bonsplitController.allPaneIds.contains(previousZoomedPaneId) {
            _ = toggleDockPaneZoom(inPane: previousZoomedPaneId)
        }
        return result
    }

    /// Creates a new surface (tab) in an existing Dock pane. Used by the tab-bar
    /// "+" buttons, the empty-pane affordance, and `surface.create --placement dock`.
    @discardableResult
    func newSurface(
        kind: DockSurfaceKind,
        inPane paneId: PaneID,
        url: URL? = nil,
        initialRequest: URLRequest? = nil,
        command: String? = nil,
        workingDirectory: String? = nil,
        sourcePanelId: UUID? = nil,
        environment: [String: String] = [:],
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        startupRestoreAgent: SessionRestorableAgentSnapshot? = nil,
        focus: Bool = true,
        preferredProfileID: UUID? = nil,
        bypassInsecureHTTPHostOnce: String? = nil,
        chromeVisibility: BrowserChromeVisibility = .visible,
        preloadInitialNavigationInBackground: Bool = false,
        transparentBackground: Bool = false,
        bypassRemoteProxy: Bool? = nil,
        allowsExternalBrowserFallback: Bool = true,
        websiteDataStore: WKWebsiteDataStore? = nil,
        applyZoomPolicy: Bool = true
    ) -> UUID? {
        if applyZoomPolicy && focus {
            return withNewTabZoomPolicy(inPane: paneId) {
                newSurface(
                    kind: kind,
                    inPane: paneId,
                    url: url,
                    initialRequest: initialRequest,
                    command: command,
                    workingDirectory: workingDirectory,
                    sourcePanelId: sourcePanelId,
                    environment: environment,
                    tmuxStartCommand: tmuxStartCommand,
                    initialInput: initialInput,
                    startupRestoreAgent: startupRestoreAgent,
                    focus: focus,
                    preferredProfileID: preferredProfileID,
                    bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
                    chromeVisibility: chromeVisibility,
                    preloadInitialNavigationInBackground: preloadInitialNavigationInBackground,
                    transparentBackground: transparentBackground,
                    bypassRemoteProxy: bypassRemoteProxy,
                    allowsExternalBrowserFallback: allowsExternalBrowserFallback,
                    websiteDataStore: websiteDataStore,
                    applyZoomPolicy: false
                )
            }
        }
        ensureLoaded()
        let source = resolveSourcePanelId(sourcePanelId, preferredPaneId: paneId)
        let resolvedBrowserProfileID = kind == .browser
            ? resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: source
            )
            : nil
        guard let panel = makePanel(
            kind: kind,
            command: command,
            url: url,
            initialRequest: initialRequest,
            configTemplate: kind == .terminal
                ? inheritedTerminalFontSizeConfig(sourcePanelId: source)
                : nil,
            environment: environment,
            workingDirectory: resolvedTerminalStartupWorkingDirectory(
                kind: kind,
                requestedWorkingDirectory: workingDirectory,
                sourcePanelId: source
            ),
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            startupRestoreAgent: startupRestoreAgent,
            preferredProfileID: resolvedBrowserProfileID,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
            chromeVisibility: chromeVisibility,
            preloadInitialNavigationInBackground:
                preloadInitialNavigationInBackground,
            transparentBackground: transparentBackground,
            bypassRemoteProxy: bypassRemoteProxy,
            allowsExternalBrowserFallback: allowsExternalBrowserFallback,
            websiteDataStore: websiteDataStore
        ) else { return nil }
        let previousFocus = focus ? nil : focusedDockPaneSelection()
        guard let tabId = attachPanelAsTab(panel, kind: kind, title: panel.displayTitle, inPane: paneId) else {
            return nil
        }
        commitStartupRestoreIfNeeded(
            panel: panel,
            snapshot: startupRestoreAgent,
            initialInput: initialInput
        )
        recordExplicitPanelCreation()
        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            panel.focus()
        } else {
            restoreDockPaneSelection(previousFocus)
        }
        return panel.id
    }

    /// Creates a new surface by splitting an existing Dock pane. Used by
    /// `pane.create --placement dock`. When the Dock tree is empty, seeds the
    /// root pane instead of splitting.
    @discardableResult
    func newSplit(
        kind: DockSurfaceKind,
        orientation: SplitOrientation,
        insertFirst: Bool,
        sourcePanelId: UUID?,
        url: URL? = nil,
        initialRequest: URLRequest? = nil,
        command: String? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        startupRestoreAgent: SessionRestorableAgentSnapshot? = nil,
        initialDividerPosition: CGFloat? = nil,
        preferredProfileID: UUID? = nil,
        chromeVisibility: BrowserChromeVisibility = .visible,
        preloadInitialNavigationInBackground: Bool = false,
        transparentBackground: Bool = false,
        bypassRemoteProxy: Bool? = nil,
        allowsExternalBrowserFallback: Bool = true,
        websiteDataStore: WKWebsiteDataStore? = nil,
        focus: Bool = true
    ) -> UUID? {
        ensureLoaded()
        let source = resolveSourcePanelId(sourcePanelId)
        let resolvedBrowserProfileID = kind == .browser
            ? resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: source
            )
            : nil
        guard let panel = makePanel(
            kind: kind,
            command: command,
            url: url,
            initialRequest: initialRequest,
            configTemplate: kind == .terminal
                ? inheritedTerminalFontSizeConfig(sourcePanelId: source)
                : nil,
            environment: environment,
            workingDirectory: resolvedTerminalStartupWorkingDirectory(
                kind: kind,
                requestedWorkingDirectory: workingDirectory,
                sourcePanelId: source
            ),
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            startupRestoreAgent: startupRestoreAgent,
            preferredProfileID: resolvedBrowserProfileID,
            chromeVisibility: chromeVisibility,
            preloadInitialNavigationInBackground:
                preloadInitialNavigationInBackground,
            transparentBackground: transparentBackground,
            bypassRemoteProxy: bypassRemoteProxy,
            allowsExternalBrowserFallback: allowsExternalBrowserFallback,
            websiteDataStore: websiteDataStore
        ) else { return nil }

        guard let source, let sourcePaneId = paneId(forPanelId: source) else {
            // Empty tree: place into the root pane rather than splitting.
            let previousFocus = focus ? nil : focusedDockPaneSelection()
            guard let rootPane = bonsplitController.allPaneIds.first,
                  let tabId = attachPanelAsTab(panel, kind: kind, title: panel.displayTitle, inPane: rootPane) else {
                return nil
            }
            commitStartupRestoreIfNeeded(
                panel: panel,
                snapshot: startupRestoreAgent,
                initialInput: initialInput
            )
            recordExplicitPanelCreation()
            if focus {
                bonsplitController.focusPane(rootPane)
                bonsplitController.selectTab(tabId)
                panel.focus()
            } else {
                restoreDockPaneSelection(previousFocus)
            }
            return panel.id
        }

        let previousFocus = focus ? nil : focusedDockPaneSelection()
        panels[panel.id] = panel
        let newTab = Bonsplit.Tab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: tabKindRaw(kind),
            isDirty: panel.isDirty,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: panel.id)
        let splitResult = withProgrammaticDockSplit {
            bonsplitController.splitPane(
                sourcePaneId,
                orientation: orientation,
                withTab: newTab,
                insertFirst: insertFirst,
                initialDividerPosition: initialDividerPosition
            )
        }
        guard splitResult != nil else {
            discardPanelOwnershipAndClose(panelId: panel.id)
            return nil
        }
        installSubscription(for: panel)
        applyVisibility(to: panel)
        commitStartupRestoreIfNeeded(
            panel: panel,
            snapshot: startupRestoreAgent,
            initialInput: initialInput
        )
        recordExplicitPanelCreation()
        if focus {
            focusPanel(panel.id)
        } else {
            restoreDockPaneSelection(previousFocus)
        }
        return panel.id
    }

    func recordExplicitPanelCreation() {
        hasAppliedConfigurationSeed = true
        if configurationLoadTask != nil { configurationSeedSuppressionGeneration = configurationLoadGeneration }
    }

    /// Runs a programmatic split (which provides its own new-pane tab) with
    /// `isProgrammaticDockSplit` set so `didSplitPane` skips the interactive
    /// auto-create / placeholder-repair path. `didSplitPane` fires synchronously
    /// from `splitPane`, so the flag only needs to cover the call itself.
    @discardableResult
    func withProgrammaticDockSplit<T>(_ body: () -> T) -> T {
        let previous = isProgrammaticDockSplit
        isProgrammaticDockSplit = true
        defer { isProgrammaticDockSplit = previous }
        return body()
    }

#if DEBUG
    func markConfigurationLoadInFlightForTesting(rootDirectory: String?) -> Int {
        hasLoadedConfiguration = true; configurationLoadGeneration += 1
        configurationLoadRootDirectory = rootDirectory; configurationLoadTask = Task {}
        return configurationLoadGeneration
    }

    func applyConfigurationIdentityForTesting(_ identity: DockConfigIdentity) {
        configurationIdentityGeneration += 1
        applyConfigurationIdentity(identity, generation: configurationIdentityGeneration)
    }
#endif

    @discardableResult
    func beginTerminalFontSizeChangeInheritance(
        token: UUID,
        change: WorkspaceTerminalFontSizeChange,
        configuredRuntimePoints: Float32,
        magnificationPercent: Int =
            GlobalFontMagnification.storedPercent,
        fallbackLineage: TerminalFontSizeLineage?,
        fallbackLineageAlreadyIncludesChange: Bool
    ) -> TerminalFontSizeChangeInheritanceContext {
        let preferredSourcePanel = focusedPanelId.flatMap {
            panels[$0] as? TerminalPanel
        }
        let dockFallbackLineage = lastTerminalFontSizeLineage
        let context = TerminalFontSizeChangeInheritanceContext(
            token: token,
            change: change,
            configuredRuntimePoints: configuredRuntimePoints,
            magnificationPercent: magnificationPercent,
            preferredSourcePanel: preferredSourcePanel,
            fallbackLineage: dockFallbackLineage ?? fallbackLineage,
            fallbackLineageAlreadyIncludesChange:
                dockFallbackLineage == nil
                && fallbackLineageAlreadyIncludesChange
        )
        activeTerminalFontSizeChangeInheritanceContext = context
        rememberDurableTerminalFontSizeLineage(context.fallbackLineage)
        return context
    }

    func endTerminalFontSizeChangeInheritance(token: UUID) {
        guard activeTerminalFontSizeChangeInheritanceContext?.token == token else {
            return
        }
        activeTerminalFontSizeChangeInheritanceContext = nil
    }

#if DEBUG
    private(set) var debugWorkspaceFontSizeLineageProbeCount = 0

    var debugActiveTerminalFontSizeChangeInitialLineageProbeCount: Int? {
        activeTerminalFontSizeChangeInheritanceContext?
            .initialLineageProbeCount
    }
#endif

    func rememberTerminalFontSizeLineageForNewTerminals(
        fallback: TerminalFontSizeLineage?,
        magnificationPercent: Int =
            GlobalFontMagnification.storedPercent
    ) {
        let focusedTerminalPanel = focusedPanelId.flatMap {
            panels[$0] as? TerminalPanel
        }
        let focusedLineage =
            focusedTerminalPanel?.surface.fontSizeLineageSnapshot(
                magnificationPercent: magnificationPercent
            )
        if let lineage = focusedLineage ?? fallback ?? lastTerminalFontSizeLineage {
            rememberDurableTerminalFontSizeLineage(lineage)
        }
    }

    /// Concrete config-following values are valid only during an active
    /// change. Persisting one would freeze the config value for future panes.
    private func rememberDurableTerminalFontSizeLineage(
        _ lineage: TerminalFontSizeLineage?
    ) {
        lastTerminalFontSizeLineage =
            lineage?.isExplicitOverride == true ? lineage : nil
    }

    private func inheritedTerminalFontSizeConfig(
        sourcePanelId: UUID?
    ) -> CmuxSurfaceConfigTemplate? {
        let sourceTerminalPanel = sourcePanelId.flatMap {
            panels[$0] as? TerminalPanel
        }
        let inheritanceContext =
            activeTerminalFontSizeChangeInheritanceContext
        let transferProjection =
            sourceTerminalPanel.flatMap {
                terminalFontSizeChangeArbiter?
                    .transferInheritanceProjection(for: $0)
            }
        let sourceLineage: TerminalFontSizeLineage?
        if let transferProjection {
            sourceLineage = transferProjection.lineage
        } else if let inheritanceContext {
            sourceLineage =
                sourceTerminalPanel?.surface
                    .fontSizeLineageForAdjustment(
                        fallbackRuntimePoints:
                            inheritanceContext
                                .configuredRuntimePoints,
                        magnificationPercent:
                            inheritanceContext
                                .magnificationPercent
                    )
        } else {
            sourceLineage =
                sourceTerminalPanel?.surface
                    .fontSizeLineageSnapshot()
        }
        let inheritedLineage: TerminalFontSizeLineage?
        if let inheritanceContext {
            inheritedLineage =
                inheritanceContext.inheritedLineage(
                    from: sourceLineage,
                    alreadyIncludesChange:
                        sourceTerminalPanel?.surface
                            .hasAppliedFontSizeChange(
                                token:
                                    inheritanceContext.token
                            ) == true
                        || transferProjection?
                            .representedRequestTokens
                            .contains(
                                inheritanceContext.token
                            ) == true
                )
        } else {
            inheritedLineage = sourceLineage
        }
        guard let lineage =
                inheritedLineage
                ?? lastTerminalFontSizeLineage else {
            return nil
        }
        guard inheritanceContext != nil || lineage.isExplicitOverride else {
            rememberDurableTerminalFontSizeLineage(nil)
            return nil
        }
        rememberDurableTerminalFontSizeLineage(lineage)
        var fontSizeChangeTokens =
            sourceTerminalPanel?.surface
                .fontSizeChangeTokensForInheritance()
            ?? []
        fontSizeChangeTokens.formUnion(
            transferProjection?.representedRequestTokens
            ?? []
        )
        var config = CmuxSurfaceConfigTemplate()
        config.fontSizeLineage = lineage
        config.fontSizeChangeToken = inheritanceContext?.token
        config.fontSizeChangeTokens =
            fontSizeChangeTokens
        return config
    }

    // MARK: - Panel construction

    private func makePanel(
        kind: DockSurfaceKind,
        command: String?,
        url: URL?,
        initialRequest: URLRequest? = nil,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
        environment: [String: String],
        workingDirectory: String,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        startupRestoreAgent: SessionRestorableAgentSnapshot? = nil,
        preferredProfileID: UUID? = nil,
        bypassInsecureHTTPHostOnce: String? = nil,
        chromeVisibility: BrowserChromeVisibility = .visible,
        preloadInitialNavigationInBackground: Bool = false,
        transparentBackground: Bool = false,
        bypassRemoteProxy: Bool? = nil,
        allowsExternalBrowserFallback: Bool = true,
        websiteDataStore: WKWebsiteDataStore? = nil
    ) -> (any Panel)? {
        switch kind {
        case .terminal:
            return makeTerminalPanel(
                command: command,
                useLoginShellWrapper: false,
                workingDirectory: workingDirectory,
                environment: environment,
                configTemplate: configTemplate,
                tmuxStartCommand: tmuxStartCommand,
                initialInput: initialInput,
                startupRestoreAgent: startupRestoreAgent,
                controlId: nil,
                controlTitle: nil
            )
        case .browser:
            guard browserAvailabilityProvider() else {
                if allowsExternalBrowserFallback,
                   let externalURL = url ?? initialRequest?.url {
                    _ = NSWorkspace.shared.open(externalURL)
                }
                return nil
            }
            return makeBrowserPanel(
                url: url,
                initialRequest: initialRequest,
                preferredProfileID: preferredProfileID,
                bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
                chromeVisibility: chromeVisibility,
                preloadInitialNavigationInBackground:
                    preloadInitialNavigationInBackground,
                transparentBackground: transparentBackground,
                bypassRemoteProxy: bypassRemoteProxy,
                websiteDataStore: websiteDataStore
            )
        }
    }

    private func makePanel(for def: DockControlDefinition, baseDirectory: String) -> (any Panel)? {
        switch def.kind {
        case .terminal:
            let workingDirectory = Self.resolvedWorkingDirectory(def.cwd, baseDirectory: baseDirectory)
            return makeTerminalPanel(
                command: def.command,
                useLoginShellWrapper: true,
                workingDirectory: workingDirectory,
                environment: def.env,
                configTemplate: inheritedTerminalFontSizeConfig(sourcePanelId: nil),
                controlId: def.id,
                controlTitle: def.title
            )
        case .browser:
            guard browserAvailabilityProvider() else { return nil }
            return makeBrowserPanel(
                url: def.url.flatMap { URL(string: $0) },
                chromeVisibility: def.showsBrowserChrome ? .visible : .chromeless
            )
        }
    }

    private func makeTerminalPanel(
        command: String?,
        useLoginShellWrapper: Bool,
        workingDirectory: String,
        environment: [String: String],
        configTemplate: CmuxSurfaceConfigTemplate?,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        startupRestoreAgent: SessionRestorableAgentSnapshot? = nil,
        controlId: String?,
        controlTitle: String?
    ) -> TerminalPanel {
        var resolvedEnvironment = environment
        if let controlId { resolvedEnvironment["CMUX_DOCK_CONTROL_ID"] = controlId }
        if let controlTitle { resolvedEnvironment["CMUX_DOCK_CONTROL_TITLE"] = controlTitle }

        let initialCommand: String?
        if let command, !command.isEmpty {
            initialCommand = useLoginShellWrapper
                ? Self.shellStartupScript(command: command, workingDirectory: workingDirectory)
                : command
        } else {
            initialCommand = nil
        }

        return TerminalPanel(
            workspaceId: workspaceId,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            initialEnvironmentOverrides: resolvedEnvironment,
            focusPlacement: .rightSidebarDock,
            runtimeSpawnPolicy: terminalStartupRestoreCoordinator.runtimeSpawnPolicy(
                requestedPolicy: .immediate,
                willRunStartupCommand: false,
                willRunStartupInput: startupRestoreAgent != nil && initialInput != nil
            )
        )
    }

    private func commitStartupRestoreIfNeeded(
        panel: any Panel,
        snapshot: SessionRestorableAgentSnapshot?,
        initialInput: String?
    ) {
        guard let snapshot, let terminal = panel as? TerminalPanel else { return }
        terminalStartupRestoreCoordinator.stage(
            panel: terminal,
            snapshot: snapshot,
            manualResumeAvailable: true,
            willRunStartupCommand: false,
            willRunStartupInput: initialInput != nil,
            resumeWorkingDirectory: snapshot.workingDirectory
        )
        terminalStartupRestoreCoordinator.commitPendingRestores(panelIDs: [terminal.id])
    }

    private func tabKindRaw(_ kind: DockSurfaceKind) -> String {
        switch kind {
        case .terminal: return "terminal"
        case .browser: return "browser"
        }
    }

    @discardableResult
    private func attachPanelAsTab(
        _ panel: any Panel,
        kind: DockSurfaceKind,
        title: String,
        inPane paneId: PaneID?
    ) -> TabID? {
        panels[panel.id] = panel
        guard let tabId = bonsplitController.createTab(
            title: title,
            icon: panel.displayIcon,
            kind: tabKindRaw(kind),
            isDirty: panel.isDirty,
            isPinned: false,
            inPane: paneId
        ) else {
            discardPanelOwnershipAndClose(panelId: panel.id)
            return nil
        }
        bindSurface(tabId, toPanelId: panel.id)
        installSubscription(for: panel)
        applyVisibility(to: panel)
        return tabId
    }

    // MARK: - Tab metadata subscriptions

    func installSubscription(for panel: any Panel) {
        if let terminal = panel as? TerminalPanel {
            configureAgentHibernationResume(for: terminal)
        }
        installAttentionRouting(for: panel)
        if let browser = panel as? BrowserPanel {
            let browserTabState = Publishers.CombineLatest4(
                browser.$pageTitle.removeDuplicates(),
                browser.$currentURL.removeDuplicates(),
                browser.$isLoading.removeDuplicates(),
                browser.$faviconPNGData.removeDuplicates(by: { $0 == $1 })
            )
            let cancellable = browserTabState
                .combineLatest(browser.$isMuted.removeDuplicates())
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak browser] _ in
                    guard let self, let browser else { return }
                    self.publishBrowserOpenTabSuggestion(for: browser)
                    guard let tabId = self.surfaceId(forPanelId: browser.id),
                          let existing = self.bonsplitController.tab(tabId) else { return }
                    // Only push fields that actually changed. The combined stream
                    // fires for any observed field, so an `isLoading` flicker during a
                    // page load would otherwise re-publish the (unchanged) title and
                    // favicon, mutating the @Observable BonsplitController and
                    // re-rendering the Dock tree for nothing. Mirrors the main area's
                    // guarded path in Workspace.installBrowserPanelSubscription.
                    let resolvedTitle = browser.displayTitle
                    let favicon = browser.faviconPNGData
                    let titleUpdate: String? =
                        existing.hasCustomTitle || existing.title == resolvedTitle
                        ? nil
                        : resolvedTitle
                    let faviconUpdate: Data?? = existing.iconImageData == favicon ? nil : .some(favicon)
                    let loadingUpdate: Bool? = existing.isLoading == browser.isLoading ? nil : browser.isLoading
                    let mutedUpdate: Bool? = existing.isAudioMuted == browser.isMuted ? nil : browser.isMuted
                    guard titleUpdate != nil || faviconUpdate != nil || loadingUpdate != nil || mutedUpdate != nil else { return }
                    self.bonsplitController.updateTab(
                        tabId,
                        title: titleUpdate,
                        iconImageData: faviconUpdate,
                        isLoading: loadingUpdate,
                        isAudioMuted: mutedUpdate
                    )
                }
            panelCancellables[panel.id] = cancellable
            publishBrowserOpenTabSuggestion(for: browser)
        } else if let filePreview = panel as? FilePreviewPanel {
            panelCancellables.removeValue(forKey: panel.id)
            filePreview.bindTabMetadata(to: self)
        } else {
            panelCancellables.removeValue(forKey: panel.id)
        }
    }

    /// Resolves the Dock tab currently owned by a file-preview panel.
    func filePreviewTabId(forPanelId panelId: UUID) -> TabID? {
        surfaceId(forPanelId: panelId)
    }

    /// Preserves a Dock custom title while accepting panel-owned metadata.
    func filePreviewTabTitlePresentation(
        for metadata: FilePreviewTabMetadata,
        panelId _: UUID,
        existingTab: Bonsplit.Tab
    ) -> (title: String?, hasCustomTitle: Bool?) {
        (existingTab.hasCustomTitle ? nil : metadata.title, nil)
    }

    /// Keeps the live terminal model and its non-custom Bonsplit tab on one
    /// title mutation path. Callers that synchronously adopt a Ghostty title
    /// invoke this directly; the publisher remains the fallback for other
    /// terminal title writers.
    private func synchronizeTerminalTabTitle(_ terminal: TerminalPanel) {
        guard let tabId = surfaceId(forPanelId: terminal.id),
              let existing = bonsplitController.tab(tabId) else {
            return
        }
        let resolvedTitle = terminal.displayTitle
        guard !existing.hasCustomTitle,
              existing.title != resolvedTitle else {
            return
        }
        bonsplitController.updateTab(tabId, title: resolvedTitle)
    }

    /// Applies an admitted Dock terminal title to the model and its tab in the
    /// same main-actor turn.
    func applyResolvedTerminalTitle(_ title: String, to terminal: TerminalPanel) {
        terminal.updateTitle(title)
        synchronizeTerminalTabTitle(terminal)
    }

    /// Applies every admitted title currently waiting on the Dock's bounded
    /// coalescer. Persistence and transfer boundaries call this before reading
    /// title metadata so their snapshots include the latest accepted value.
    func flushPendingTerminalTitleUpdates() {
        terminalTitleUpdateCoalescer.flushNow()
        applyPendingTerminalTitleUpdates()
    }

    /// Preserves shell-state/title ordering for one surface without forcing
    /// unrelated Dock terminals through the same early flush.
    func flushPendingTerminalTitleUpdate(panelId: UUID) {
        guard let update = pendingTerminalTitleUpdates.removeValue(
            forKey: panelId
        ) else {
            return
        }
        applyPendingTerminalTitleUpdate(update, panelId: panelId)
    }

    /// Drops an update captured from a panel lifecycle that is ending.
    func discardPendingTerminalTitleUpdate(panelId: UUID) {
        pendingTerminalTitleUpdates.removeValue(forKey: panelId)
    }

    private func enqueueTerminalTitleUpdate(
        _ title: String,
        terminal: TerminalPanel
    ) {
        pendingTerminalTitleUpdates[terminal.id] = PendingTerminalTitleUpdate(
            title: title,
            sourceSurface: terminal.surface,
            sourceTerminalLifecycleId: terminal.surface.terminalLifecycleId
        )
        terminalTitleUpdateCoalescer.signal(
            delay: PanelTitleUpdateCoalescingSettings.delay(settings: settings)
        ) { [weak self] in
            self?.applyPendingTerminalTitleUpdates()
        }
    }

    private func applyPendingTerminalTitleUpdates() {
        guard !pendingTerminalTitleUpdates.isEmpty else { return }
        let updates = pendingTerminalTitleUpdates
        pendingTerminalTitleUpdates.removeAll(keepingCapacity: true)
        for (panelId, update) in updates {
            applyPendingTerminalTitleUpdate(update, panelId: panelId)
        }
    }

    private func applyPendingTerminalTitleUpdate(
        _ update: PendingTerminalTitleUpdate,
        panelId: UUID
    ) {
        guard let sourceSurface = update.sourceSurface,
              let terminal = panels[panelId] as? TerminalPanel,
              terminal.surface === sourceSurface,
              sourceSurface.terminalLifecycleId == update.sourceTerminalLifecycleId else {
            return
        }
        applyResolvedTerminalTitle(update.title, to: terminal)
    }

    @discardableResult
    func applyTerminalTitleChange(_ change: GhosttyTitleChange) -> Bool {
        guard change.tabId == workspaceId,
              let terminal = panels[change.surfaceId] as? TerminalPanel,
              change.matches(
                  sourceSurface: terminal.surface,
                  terminalLifecycleID: terminal.surface.terminalLifecycleId
              ) else {
            return false
        }
        let title = change.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return true }
        guard shouldApplyRestoredPanelTitle(
            panelId: change.surfaceId,
            rawTitle: title
        ) else {
            return true
        }
        enqueueTerminalTitleUpdate(title, terminal: terminal)
        return true
    }

    // MARK: - BonsplitDelegate

    /// Closes and removes any panels whose Bonsplit tab is no longer present in
    /// the tree (tab close, pane close, or merge).
    func reconcilePanels() {
        let live = Set(bonsplitController.allTabIds)
        let staleTabIds = surfaceIdToPanelId.keys.filter { !live.contains($0) }
        let stalePanelIds = Set(staleTabIds.compactMap { surfaceIdToPanelId[$0] })
        for tabId in staleTabIds {
            removeSurfaceMapping(forSurfaceId: tabId)
        }
        let livePanelIds = Set(surfaceIdToPanelId.values)
        for panelId in stalePanelIds.subtracting(livePanelIds) {
            discardPanelStateAndClose(panelId: panelId)
        }
    }

    private static func normalizedBaseDirectory(_ directory: String?) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func currentBaseDirectory() -> String {
        if let directory = rootDirectoryOverride ?? Self.normalizedBaseDirectory(baseDirectoryProvider()) {
            return directory
        }
        return resolvedBaseDirectory
    }

    private func resolvedTerminalStartupWorkingDirectory(
        kind: DockSurfaceKind,
        requestedWorkingDirectory: String?,
        sourcePanelId: UUID?
    ) -> String {
        guard kind == .terminal else { return currentBaseDirectory() }
        let baseDirectory = currentBaseDirectory()
        let inheritedDirectory = settings.value(for: settingsCatalog.app.workspaceInheritWorkingDirectory)
            ? sourcePanelId.flatMap { inheritedLocalTerminalWorkingDirectory(for: $0) }
            : nil
        if let requestedDirectory = TerminalWorkingDirectoryResolver.normalized(requestedWorkingDirectory) { return requestedDirectory }
        if let inheritedDirectory, !inheritedDirectory.isEmpty { return inheritedDirectory }
        return baseDirectory
    }

    // MARK: - Config loading

    func reload() {
        removeAllPanels()
        hasLoadedConfiguration = true
        hasAppliedConfigurationSeed = false
        startConfigurationLoad(replacingPanels: true)
    }

    func trustAndReload() {
        if let trustRequest {
            CmuxActionTrust.shared.trust(trustRequest.descriptor)
        }
        reload()
    }

    private func startConfigurationLoad(replacingPanels: Bool) {
        configurationLoadGeneration += 1
        let generation = configurationLoadGeneration
        let rootDirectory = currentBaseDirectory()
        configurationLoadRootDirectory = rootDirectory
        configurationIdentityTask?.cancel()
        configurationLoadTask?.cancel()
        let scope = scope
        configurationLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.loadConfigurationSnapshot(scope: scope, rootDirectory: rootDirectory)
            guard !Task.isCancelled else { return }
            await self?.applyConfigurationLoadResult(
                result,
                generation: generation,
                replacingPanels: replacingPanels
            )
        }
    }

    private func applyConfigurationIdentity(_ current: DockConfigIdentity, generation: Int) {
        guard generation == configurationIdentityGeneration else { return }
        configurationIdentityTask = nil
        if lastLoadedConfigIdentity == nil, hasAppliedConfigurationSeed {
            lastLoadedConfigIdentity = current
            resolvedBaseDirectory = current.baseDirectory
            return
        }
        guard current.requiresPanelReload(comparedTo: lastLoadedConfigIdentity) else {
            lastLoadedConfigIdentity = current
            resolvedBaseDirectory = current.baseDirectory
            return
        }
        reload()
    }

    private nonisolated static func loadConfigurationSnapshot(scope: DockScope, rootDirectory: String?) -> DockConfigurationLoadResult {
        do {
            return .resolved(try resolve(scope: scope, rootDirectory: rootDirectory))
        } catch {
            return .failed(
                identity: configIdentity(scope: scope, rootDirectory: rootDirectory),
                message: configurationLoadErrorMessage(for: error)
            )
        }
    }

    func applyConfigurationLoadResult(
        _ result: DockConfigurationLoadResult,
        generation: Int,
        replacingPanels: Bool
    ) {
        guard generation == configurationLoadGeneration else { return }
        configurationLoadTask = nil; configurationLoadRootDirectory = nil
        errorMessage = nil
        trustRequest = nil
        activeConfigURL = nil

        switch result {
        case .resolved(let resolution):
            lastLoadedConfigIdentity = Self.configIdentity(for: resolution)
            activeConfigURL = resolution.sourceURL
            resolvedBaseDirectory = resolution.baseDirectory
            if let request = trustRequestIfNeeded(for: resolution) {
                sourceLabel = String(localized: "dock.source.project", defaultValue: "Project Dock")
                trustRequest = request
                return
            }
            sourceLabel = Self.sourceLabel(for: resolution)
            let shouldSeed = configurationSeedSuppressionGeneration != generation && (replacingPanels || !hasAppliedConfigurationSeed)
            if shouldSeed {
                seed(definitions: resolution.controls, baseDirectory: resolution.baseDirectory)
            }
            if configurationSeedSuppressionGeneration == generation { configurationSeedSuppressionGeneration = nil }
            hasAppliedConfigurationSeed = true
        case .failed(let identity, let message):
            lastLoadedConfigIdentity = identity
            activeConfigURL = identity.sourcePath.map { URL(fileURLWithPath: $0, isDirectory: false) }
            resolvedBaseDirectory = identity.baseDirectory
            sourceLabel = String(localized: "dock.source.error", defaultValue: "Dock")
            errorMessage = message
        }
    }

    /// Default per-control height (points) used for divider math when a config
    /// entry omits `height`. Matches the legacy Dock's minimum terminal height.
    private static let defaultSeedHeight: Double = 200

    /// Seeds the Dock tree from config. The legacy config is a flat list, so it
    /// seeds a vertical stack (each entry split below the previous) to mirror the
    /// Dock's prior top-to-bottom layout; users can then re-tile in-app.
    ///
    /// Legacy `height` values are honored as relative sizing: each split's
    /// initial divider is set from the requested-height ratios (a fractional
    /// Bonsplit tree cannot pin absolute point heights, but the proportions are
    /// preserved and remain user-resizable).
    private func seed(definitions: [DockControlDefinition], baseDirectory: String) {
        // Build panels first so divider math runs over the entries actually
        // created (e.g. browser entries are skipped when the browser is disabled).
        let created: [(definition: DockControlDefinition, panel: any Panel)] = definitions.compactMap { definition in
            guard let panel = makePanel(for: definition, baseDirectory: baseDirectory) else { return nil }
            return (definition: definition, panel: panel)
        }
        guard !created.isEmpty else { return }

        let heights = created.map { max($0.definition.height ?? Self.defaultSeedHeight, 1) }
        let rootPaneId = bonsplitController.allPaneIds.first
        var previousPanelId: UUID?

        for (index, entry) in created.enumerated() {
            let definition = entry.definition
            let panel = entry.panel

            if let previousPanelId, let sourcePaneId = paneId(forPanelId: previousPanelId) {
                // Divider = the height share of everything already placed above
                // this split (the source/top child) within the space remaining
                // from this entry downward.
                let remainingTotal = heights[(index - 1)...].reduce(0, +)
                let divider = CGFloat(min(max(heights[index - 1] / remainingTotal, 0.1), 0.9))
                panels[panel.id] = panel
                let newTab = Bonsplit.Tab(
                    title: definition.title,
                    icon: panel.displayIcon,
                    kind: tabKindRaw(definition.kind),
                    isDirty: panel.isDirty,
                    isPinned: false
                )
                bindSurface(newTab.id, toPanelId: panel.id)
                let seedSplitResult = withProgrammaticDockSplit {
                    bonsplitController.splitPane(
                        sourcePaneId,
                        orientation: .vertical,
                        withTab: newTab,
                        insertFirst: false,
                        initialDividerPosition: divider
                    )
                }
                guard seedSplitResult != nil else {
                    discardPanelOwnershipAndClose(panelId: panel.id)
                    continue
                }
                installSubscription(for: panel)
                applyVisibility(to: panel)
            } else {
                guard attachPanelAsTab(panel, kind: definition.kind, title: definition.title, inPane: rootPaneId) != nil else {
                    continue
                }
            }
            previousPanelId = panel.id
        }
        applyVisibilityToAllPanels()
    }

    private func trustRequestIfNeeded(for resolution: DockConfigResolution) -> DockTrustRequest? {
        guard resolution.isProjectSource, let sourceURL = resolution.sourceURL else { return nil }
        let descriptor = Self.trustDescriptor(for: resolution)
        guard !CmuxActionTrust.shared.isTrusted(descriptor) else { return nil }
        return DockTrustRequest(descriptor: descriptor, configPath: sourceURL.path)
    }

    func openConfiguration() {
        let target: URL
        do {
            if let activeConfigURL {
                target = activeConfigURL
            } else {
                target = try Self.preferredEditableConfigURL(scope: scope, rootDirectory: currentBaseDirectory())
            }
        } catch {
            errorMessage = Self.configurationOpenErrorMessage(for: error)
            return
        }

        Task { [weak self] in
            let result: (target: URL?, errorMessage: String?) = await Task.detached(priority: .userInitiated) {
                do {
                    try Self.prepareEditableConfig(at: target)
                    return (target, nil)
                } catch {
                    return (nil, Self.configurationOpenErrorMessage(for: error))
                }
            }.value

            guard let self else { return }
            if let target = result.target {
                NSWorkspace.shared.open(target)
            } else if let message = result.errorMessage {
                self.errorMessage = message
            }
        }
    }
}
