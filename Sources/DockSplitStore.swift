import AppKit
import Bonsplit
import Combine
import CmuxAppKitSupportUI
import CmuxCore
import CmuxTerminal
import Observation
import SwiftUI

@MainActor
@Observable
final class DockSplitStore: BonsplitDelegate {
    let workspaceId: UUID
    let bonsplitController: BonsplitController

    /// Which Dock this store backs: `.workspace` (per-workspace, seeded from the
    /// project `.cmux/dock.json`) or `.global` (one app-wide Dock seeded from
    /// `~/.config/cmux/dock.json` that persists everywhere). Drives config
    /// resolution and how cross-container moves resolve a reference window.
    let scope: DockScope

    private(set) var sourceLabel: String = ""
    private(set) var errorMessage: String?
    private(set) var trustRequest: DockTrustRequest?
    private(set) var isVisibleInUI: Bool = false
    private(set) var renderHostId: UUID?
    private var visibleUIHostIds: Set<UUID> = []

    private let baseDirectoryProvider: () -> String?
    private let remoteBrowserSettingsProvider: () -> DockRemoteBrowserSettings
    private let browserAvailabilityProvider: () -> Bool
    // Internal so cross-container transfers can move live panels without tearing them down.
    var panels: [UUID: any Panel] = [:]
    var surfaceIdToPanelId: [TabID: UUID] = [:]
    var panelCancellables: [UUID: AnyCancellable] = [:]
    var detachedSurfaceTransfersByPanelId: [UUID: Workspace.DetachedSurfaceTransfer] = [:]
    private var hasLoadedConfiguration = false
    private var configurationLoadTask: Task<Void, Never>?
    private var configurationIdentityTask: Task<Void, Never>?
    private var configurationLoadGeneration = 0
    private var configurationIdentityGeneration = 0
    private var configurationLoadRootDirectory: String?
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
    @ObservationIgnored var terminalViewReattachCoalescingDepth = 0
    @ObservationIgnored var pendingTerminalViewReattachPanelIds: Set<UUID> = []

    /// Weak registry of every live Dock store. Lets control-surface routing
    /// resolve a Dock surface/pane by querying only the workspaces that actually
    /// have a Dock (their authoritative `containsPanel`/`containsPane`), instead
    /// of walking every window × workspace tab on each resolution. Entries drop
    /// automatically when a store deallocates; accessed on the main actor only.
    @MainActor private static let liveStoresTable = NSHashTable<DockSplitStore>.weakObjects()

    /// Snapshot of the currently live Dock stores.
    @MainActor static var liveStores: [DockSplitStore] { liveStoresTable.allObjects }

    init(
        workspaceId: UUID,
        scope: DockScope = .workspace,
        baseDirectoryProvider: @escaping () -> String?,
        remoteBrowserSettingsProvider: @escaping () -> DockRemoteBrowserSettings = { .local },
        browserAvailabilityProvider: @escaping () -> Bool = { BrowserAvailabilitySettings.isEnabled() }
    ) {
        self.workspaceId = workspaceId
        self.scope = scope
        self.baseDirectoryProvider = baseDirectoryProvider
        self.remoteBrowserSettingsProvider = remoteBrowserSettingsProvider
        self.browserAvailabilityProvider = browserAvailabilityProvider
        self.bonsplitController = BonsplitController(configuration: Self.makeConfiguration())
        self.sourceLabel = String(localized: "dock.source.title", defaultValue: "Dock")
        self.bonsplitController.delegate = self
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
        // Register only after every stored property is initialized.
        Self.liveStoresTable.add(self)
    }

    // MARK: - Lookups

    func currentRemoteBrowserSettings() -> DockRemoteBrowserSettings { remoteBrowserSettingsProvider() }

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

    func browserPanel(owning responder: NSResponder?, in window: NSWindow?) -> BrowserPanel? {
        guard let responder, let window else { return nil }
        if let focused = focusedPanelId,
           let browser = panels[focused] as? BrowserPanel,
           browser.ownedFocusIntent(for: responder, in: window) != nil {
            return browser
        }
        for (panelId, panel) in panels {
            guard panelId != focusedPanelId,
                  let browser = panel as? BrowserPanel,
                  browser.ownedFocusIntent(for: responder, in: window) != nil else {
                continue
            }
            return browser
        }
        return nil
    }

    func surfaceId(forPanelId panelId: UUID) -> TabID? {
        surfaceIdToPanelId.first { $0.value == panelId }?.key
    }

    func paneId(forPanelId panelId: UUID) -> PaneID? {
        guard let tabId = surfaceId(forPanelId: panelId) else { return nil }
        for paneId in bonsplitController.allPaneIds
        where bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId }) {
            return paneId
        }
        return nil
    }

    var focusedPanelId: UUID? {
        guard let paneId = bonsplitController.focusedPaneId,
              let tabId = bonsplitController.selectedTab(inPane: paneId)?.id else { return nil }
        return surfaceIdToPanelId[tabId]
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
            renderHostId = nil
        }
        guard isVisibleInUI != visible else { return }
        isVisibleInUI = visible
        applyFocusedDockSelection()
    }

    func setVisibleInUI(_ visible: Bool, hostId: UUID) {
        let previousRenderHostId = renderHostId
        if visible {
            visibleUIHostIds.insert(hostId)
            if renderHostId == nil {
                renderHostId = hostId
            }
        } else {
            visibleUIHostIds.remove(hostId)
            if renderHostId == hostId {
                renderHostId = visibleUIHostIds.first
            }
        }
        let anyHostVisible = !visibleUIHostIds.isEmpty
        guard isVisibleInUI != anyHostVisible || renderHostId != previousRenderHostId else { return }
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

    func focusFirstControl() -> Bool {
        guard let paneId = bonsplitController.allPaneIds.first else { return false }
        bonsplitController.focusPane(paneId)
        guard let tabId = bonsplitController.selectedTab(inPane: paneId)?.id,
              let panelId = surfaceIdToPanelId[tabId],
              let panel = panels[panelId] else { return false }
        panel.focus()
        return true
    }

    // MARK: - In-app creation

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
        environment: [String: String] = [:],
        tmuxStartCommand: String? = nil,
        focus: Bool = true,
        preferredProfileID: UUID? = nil,
        bypassInsecureHTTPHostOnce: String? = nil
    ) -> UUID? {
        ensureLoaded()
        guard let panel = makePanel(
            kind: kind,
            command: command,
            url: url,
            initialRequest: initialRequest,
            environment: environment,
            workingDirectory: workingDirectory ?? currentBaseDirectory(),
            tmuxStartCommand: tmuxStartCommand,
            preferredProfileID: preferredProfileID,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        ) else { return nil }
        let previousFocus = focus ? nil : focusedDockPaneSelection()
        guard let tabId = attachPanelAsTab(panel, kind: kind, title: panel.displayTitle, inPane: paneId, tracksTerminalTitle: true) else {
            return nil
        }
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
        command: String? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        tmuxStartCommand: String? = nil,
        initialDividerPosition: CGFloat? = nil,
        focus: Bool = true
    ) -> UUID? {
        ensureLoaded()
        guard let panel = makePanel(
            kind: kind,
            command: command,
            url: url,
            environment: environment,
            workingDirectory: workingDirectory ?? currentBaseDirectory(),
            tmuxStartCommand: tmuxStartCommand
        ) else { return nil }

        guard let source = resolveSourcePanelId(sourcePanelId), let sourcePaneId = paneId(forPanelId: source) else {
            // Empty tree: place into the root pane rather than splitting.
            let previousFocus = focus ? nil : focusedDockPaneSelection()
            guard let rootPane = bonsplitController.allPaneIds.first,
                  let tabId = attachPanelAsTab(panel, kind: kind, title: panel.displayTitle, inPane: rootPane, tracksTerminalTitle: true) else {
                return nil
            }
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
        surfaceIdToPanelId[newTab.id] = panel.id
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
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: panel.id)
            panel.close()
            return nil
        }
        installSubscription(for: panel, tracksTerminalTitle: true)
        applyVisibility(to: panel)
        recordExplicitPanelCreation()
        if focus {
            focusPanel(panel.id)
        } else {
            restoreDockPaneSelection(previousFocus)
        }
        return panel.id
    }

    /// Resolves a Dock pane for `surface.create --placement dock`. An explicit
    /// `requestedPaneID` must match a Dock pane (else `nil` → the caller reports
    /// not-found, like the workspace path); with no explicit id, returns the
    /// focused/first Dock pane. Ensures config is loaded so the Dock always has
    /// at least its root pane.
    func resolvePane(requestedPaneID: UUID?) -> PaneID? {
        ensureLoaded()
        if let requestedPaneID {
            return bonsplitController.allPaneIds.first(where: { $0.id == requestedPaneID })
        }
        return bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first
    }

    /// Whether a panel id is present in the Dock tree.
    func containsPanel(_ panelId: UUID) -> Bool {
        return panels[panelId] != nil
    }
    func containsPane(_ paneId: UUID) -> Bool { bonsplitController.allPaneIds.contains(where: { $0.id == paneId }) }

    func focusPanel(_ panelId: UUID) {
        guard let paneId = paneId(forPanelId: panelId), let tabId = surfaceId(forPanelId: panelId) else { return }
        bonsplitController.focusPane(paneId)
        bonsplitController.selectTab(tabId)
        applyDockSelection(tabId: tabId, inPane: paneId)
    }

    private func resolveSourcePanelId(_ requested: UUID?) -> UUID? {
        if let requested, panels[requested] != nil { return requested }
        if let focused = focusedPanelId { return focused }
        return panels.keys.first
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
#endif

    // MARK: - Panel construction

    private func makePanel(
        kind: DockSurfaceKind,
        command: String?,
        url: URL?,
        initialRequest: URLRequest? = nil,
        environment: [String: String],
        workingDirectory: String,
        tmuxStartCommand: String? = nil,
        preferredProfileID: UUID? = nil,
        bypassInsecureHTTPHostOnce: String? = nil
    ) -> (any Panel)? {
        switch kind {
        case .terminal:
            return makeTerminalPanel(
                command: command,
                useLoginShellWrapper: false,
                workingDirectory: workingDirectory,
                environment: environment,
                tmuxStartCommand: tmuxStartCommand,
                controlId: nil,
                controlTitle: nil
            )
        case .browser:
            guard browserAvailabilityProvider() else {
                if let externalURL = url ?? initialRequest?.url { _ = NSWorkspace.shared.open(externalURL) }
                return nil
            }
            return makeBrowserPanel(
                url: url,
                initialRequest: initialRequest,
                preferredProfileID: preferredProfileID,
                bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
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
                controlId: def.id,
                controlTitle: def.title
            )
        case .browser:
            guard browserAvailabilityProvider() else { return nil }
            return makeBrowserPanel(url: def.url.flatMap { URL(string: $0) })
        }
    }

    private func makeTerminalPanel(
        command: String?,
        useLoginShellWrapper: Bool,
        workingDirectory: String,
        environment: [String: String],
        tmuxStartCommand: String? = nil,
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
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialEnvironmentOverrides: resolvedEnvironment,
            focusPlacement: .rightSidebarDock
        )
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
        inPane paneId: PaneID?,
        tracksTerminalTitle: Bool
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
            panels.removeValue(forKey: panel.id)
            panel.close()
            return nil
        }
        surfaceIdToPanelId[tabId] = panel.id
        installSubscription(for: panel, tracksTerminalTitle: tracksTerminalTitle)
        applyVisibility(to: panel)
        return tabId
    }

    // MARK: - Tab metadata subscriptions

    func installSubscription(for panel: any Panel, tracksTerminalTitle: Bool) {
        if let browser = panel as? BrowserPanel {
            let cancellable = Publishers.CombineLatest4(
                browser.$pageTitle.removeDuplicates(),
                browser.$isLoading.removeDuplicates(),
                browser.$faviconPNGData.removeDuplicates(by: { $0 == $1 }),
                browser.$isMuted.removeDuplicates()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak browser] _ in
                guard let self, let browser, let tabId = self.surfaceId(forPanelId: browser.id),
                      let existing = self.bonsplitController.tab(tabId) else { return }
                // Only push fields that actually changed. CombineLatest4 fires on
                // ANY of the four publishers, so an `isLoading` flicker during a
                // page load would otherwise re-publish the (unchanged) title and
                // favicon, mutating the @Observable BonsplitController and
                // re-rendering the Dock tree for nothing. Mirrors the main area's
                // guarded path in Workspace.installBrowserPanelSubscription.
                let resolvedTitle = browser.displayTitle
                let favicon = browser.faviconPNGData
                let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
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
        } else if tracksTerminalTitle, let terminal = panel as? TerminalPanel {
            let cancellable = terminal.$title
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak terminal] _ in
                    guard let self, let terminal, let tabId = self.surfaceId(forPanelId: terminal.id),
                          let existing = self.bonsplitController.tab(tabId) else { return }
                    // Skip the @Observable mutation when the resolved title is
                    // unchanged, so a terminal re-emitting the same title does not
                    // re-render the Dock tree.
                    let resolvedTitle = terminal.displayTitle
                    guard existing.title != resolvedTitle else { return }
                    self.bonsplitController.updateTab(tabId, title: resolvedTitle)
                }
            panelCancellables[panel.id] = cancellable
        }
    }

    // MARK: - BonsplitDelegate

    /// Closes and removes any panels whose Bonsplit tab is no longer present in
    /// the tree (tab close, pane close, or merge).
    func reconcilePanels() {
        let live = Set(bonsplitController.allTabIds)
        let staleTabIds = surfaceIdToPanelId.keys.filter { !live.contains($0) }
        for tabId in staleTabIds {
            guard let panelId = surfaceIdToPanelId.removeValue(forKey: tabId) else { continue }
            panelCancellables[panelId]?.cancel()
            panelCancellables.removeValue(forKey: panelId)
            detachedSurfaceTransfersByPanelId.removeValue(forKey: panelId)
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspaceId, surfaceId: panelId)
            if let panel = panels.removeValue(forKey: panelId) { panel.close() }
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

    private func removeAllPanels() {
        let tabIds = Set(bonsplitController.allTabIds)
        pendingCloseConfirmDockTabIds.removeAll(); tabCloseButtonCloseDockTabIds.removeAll()
        forceCloseDockTabIds.formUnion(tabIds)
        defer { forceCloseDockTabIds.subtract(tabIds) }
        for tabId in tabIds { _ = bonsplitController.closeTab(tabId) }
        collapseToSingleEmptyPane()
        reconcilePanels()
        for panel in panels.values { panel.close() }
        panels.removeAll(); surfaceIdToPanelId.removeAll()
        detachedSurfaceTransfersByPanelId.removeAll()
        panelCancellables.values.forEach { $0.cancel() }
        panelCancellables.removeAll()
    }

    private func cancelConfigurationTasks() {
        configurationLoadGeneration += 1
        configurationIdentityGeneration += 1
        configurationLoadTask?.cancel()
        configurationIdentityTask?.cancel()
        configurationLoadTask = nil; configurationIdentityTask = nil; configurationLoadRootDirectory = nil
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
            // Config terminals carry a user-supplied title; keep it static
            // (don't track the live process title) to match Dock's prior look.
            let tracksTitle = definition.kind == .browser

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
                surfaceIdToPanelId[newTab.id] = panel.id
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
                    surfaceIdToPanelId.removeValue(forKey: newTab.id)
                    panels.removeValue(forKey: panel.id)
                    panel.close()
                    continue
                }
                installSubscription(for: panel, tracksTerminalTitle: tracksTitle)
                applyVisibility(to: panel)
            } else {
                guard attachPanelAsTab(panel, kind: definition.kind, title: definition.title, inPane: rootPaneId, tracksTerminalTitle: tracksTitle) != nil else {
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
