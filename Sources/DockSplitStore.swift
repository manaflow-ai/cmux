import AppKit
import Bonsplit
import Combine
import CmuxAppKitSupportUI
import CmuxCore
import CmuxTerminal
import Observation
import SwiftUI

/// Hosts the Dock's own Bonsplit tree of `Panel`s — terminals and browsers —
/// rendered in the right sidebar with the same split machinery as the main
/// content area. Each workspace owns one instance via `Workspace.dockSplit`.
///
/// This is a lean parallel to `Workspace`'s main-area container: it owns its own
/// `BonsplitController`, panel registry, and `BonsplitDelegate`, reusing
/// `TerminalPanel`/`BrowserPanel` (so Dock browsers share the same browser stack
/// — cookies, profiles, devtools — as main-split browsers).
@MainActor
@Observable
final class DockSplitStore: BonsplitDelegate {
    let workspaceId: UUID
    let bonsplitController: BonsplitController

    private(set) var sourceLabel: String = ""
    private(set) var errorMessage: String?
    private(set) var trustRequest: DockTrustRequest?
    private(set) var isVisibleInUI: Bool = false

    private let baseDirectoryProvider: () -> String?
    private let remoteBrowserSettingsProvider: () -> DockRemoteBrowserSettings
    private var panels: [UUID: any Panel] = [:]
    private var surfaceIdToPanelId: [TabID: UUID] = [:]
    private var panelCancellables: [UUID: AnyCancellable] = [:]
    private var hasLoadedConfiguration = false
    private var configurationLoadTask: Task<Void, Never>?
    private var configurationIdentityTask: Task<Void, Never>?
    private var configurationLoadGeneration = 0
    private var configurationIdentityGeneration = 0
    private var activeConfigURL: URL?
    private var rootDirectoryOverride: String?
    private var resolvedBaseDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    /// The resolved config identity last loaded into the Dock tree. Project
    /// config lookup walks upward, so multiple workspace directories can share
    /// one authoritative `.cmux/dock.json`.
    private var lastLoadedConfigIdentity: DockConfigIdentity?
    @ObservationIgnored var hasAppliedConfigurationSeed = false
    @ObservationIgnored var forceCloseDockTabIds: Set<TabID> = []
    @ObservationIgnored var pendingCloseConfirmDockTabIds: Set<TabID> = []
    @ObservationIgnored var tabCloseButtonCloseDockTabIds: Set<TabID> = []

    init(
        workspaceId: UUID,
        baseDirectoryProvider: @escaping () -> String?,
        remoteBrowserSettingsProvider: @escaping () -> DockRemoteBrowserSettings = { .local }
    ) {
        self.workspaceId = workspaceId
        self.baseDirectoryProvider = baseDirectoryProvider
        self.remoteBrowserSettingsProvider = remoteBrowserSettingsProvider
        self.bonsplitController = BonsplitController(configuration: Self.makeConfiguration())
        self.sourceLabel = String(localized: "dock.source.title", defaultValue: "Dock")
        self.bonsplitController.delegate = self
        self.bonsplitController.onTabCloseRequest = { [weak self] tabId, _, source in
            guard source == .closeButton else { return }
            self?.tabCloseButtonCloseDockTabIds.insert(tabId)
        }
        // Drop the controller's default welcome tab so the root pane starts
        // empty and renders the in-app create affordance until config seeds it.
        for tabId in bonsplitController.allTabIds {
            _ = bonsplitController.closeTab(tabId)
        }
    }

    // MARK: - Lookups

    func panel(for tabId: TabID) -> (any Panel)? {
        guard let panelId = surfaceIdToPanelId[tabId] else { return nil }
        return panels[panelId]
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

    private func surfaceId(forPanelId panelId: UUID) -> TabID? {
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
    func setActive(isVisible: Bool, mode: RightSidebarMode) {
        let shouldBeVisible = isVisible && mode == .dock
        if shouldBeVisible {
            if hasLoadedConfiguration {
                reloadIfBaseDirectoryChanged()
            } else {
                ensureLoaded()
            }
        }
        setVisibleInUI(shouldBeVisible)
    }

    func setRootDirectory(_ directory: String?) {
        rootDirectoryOverride = Self.normalizedBaseDirectory(directory)
    }

    /// Re-seeds the Dock when the workspace's base directory changed since the
    /// last config load (so a different project's `.cmux/dock.json` applies).
    /// Re-seeding replaces the tree, matching the prior Dock lifecycle.
    private func reloadIfBaseDirectoryChanged() {
        guard hasLoadedConfiguration else { return }
        guard configurationLoadTask == nil else { return }
        configurationIdentityGeneration += 1
        let generation = configurationIdentityGeneration
        let rootDirectory = currentBaseDirectory()
        configurationIdentityTask?.cancel()
        configurationIdentityTask = Task.detached(priority: .utility) { [weak self] in
            let current = Self.configIdentity(rootDirectory: rootDirectory)
            guard !Task.isCancelled else { return }
            await self?.applyConfigurationIdentity(current, generation: generation)
        }
    }

    func setVisibleInUI(_ visible: Bool) {
        guard isVisibleInUI != visible else { return }
        isVisibleInUI = visible
        applyVisibilityToAllPanels()
    }

    /// Tears down every Dock panel (closing terminals/browsers and their
    /// portals). Called from `Workspace.teardownAllPanels()` on workspace close.
    func closeAllPanels() {
        cancelConfigurationTasks()
        setVisibleInUI(false)
        removeAllPanels()
    }

    private func ensureLoaded() {
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
        command: String? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        tmuxStartCommand: String? = nil,
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
        guard let tabId = attachPanelAsTab(panel, kind: kind, title: panel.displayTitle, inPane: paneId, tracksTerminalTitle: true) else {
            return nil
        }
        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            panel.focus()
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
            guard let rootPane = bonsplitController.allPaneIds.first,
                  let tabId = attachPanelAsTab(panel, kind: kind, title: panel.displayTitle, inPane: rootPane, tracksTerminalTitle: true) else {
                return nil
            }
            if focus {
                bonsplitController.focusPane(rootPane)
                bonsplitController.selectTab(tabId)
                panel.focus()
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
        guard bonsplitController.splitPane(
            sourcePaneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst,
            initialDividerPosition: initialDividerPosition
        ) != nil else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: panel.id)
            panel.close()
            return nil
        }
        installSubscription(for: panel, tracksTerminalTitle: true)
        applyVisibility(to: panel)
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
        ensureLoaded()
        return panels[panelId] != nil
    }
    func containsPane(_ paneId: UUID) -> Bool { bonsplitController.allPaneIds.contains(where: { $0.id == paneId }) }

    /// Creates a new surface in the currently focused Dock pane (Dock toolbar "+" menu).
    func newInFocusedPane(kind: DockSurfaceKind) {
        ensureLoaded()
        guard let paneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else { return }
        _ = newSurface(kind: kind, inPane: paneId, focus: true)
    }

    func focusPanel(_ panelId: UUID) {
        guard let paneId = paneId(forPanelId: panelId), let tabId = surfaceId(forPanelId: panelId) else { return }
        bonsplitController.focusPane(paneId)
        bonsplitController.selectTab(tabId)
        panels[panelId]?.focus()
    }

    private func resolveSourcePanelId(_ requested: UUID?) -> UUID? {
        if let requested, panels[requested] != nil { return requested }
        if let focused = focusedPanelId { return focused }
        return panels.keys.first
    }

    // MARK: - Panel construction

    private func makePanel(
        kind: DockSurfaceKind,
        command: String?,
        url: URL?,
        environment: [String: String],
        workingDirectory: String,
        tmuxStartCommand: String? = nil
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
            guard BrowserAvailabilitySettings.isEnabled() else {
                if let url { _ = NSWorkspace.shared.open(url) }
                return nil
            }
            return makeBrowserPanel(url: url)
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
            guard BrowserAvailabilitySettings.isEnabled() else { return nil }
            return makeBrowserPanel(url: def.url.flatMap { URL(string: $0) })
        }
    }

    /// Builds a Dock browser panel, forwarding the workspace's remote-browser
    /// settings so Dock browsers share the same proxy / data store as main-area
    /// browser panes (correct for remote/cloud workspaces).
    private func makeBrowserPanel(url: URL?) -> BrowserPanel {
        let settings = remoteBrowserSettingsProvider()
        return BrowserPanel(
            workspaceId: workspaceId,
            initialURL: url,
            proxyEndpoint: settings.proxyEndpoint,
            bypassRemoteProxy: settings.bypassRemoteProxy,
            isRemoteWorkspace: settings.isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: settings.remoteWebsiteDataStoreIdentifier
        )
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

    private func installSubscription(for panel: any Panel, tracksTerminalTitle: Bool) {
        if let browser = panel as? BrowserPanel {
            let cancellable = Publishers.CombineLatest4(
                browser.$pageTitle.removeDuplicates(),
                browser.$isLoading.removeDuplicates(),
                browser.$faviconPNGData.removeDuplicates(by: { $0 == $1 }),
                browser.$isMuted.removeDuplicates()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak browser] _ in
                guard let self, let browser, let tabId = self.surfaceId(forPanelId: browser.id) else { return }
                self.bonsplitController.updateTab(
                    tabId,
                    title: browser.displayTitle,
                    iconImageData: .some(browser.faviconPNGData),
                    isLoading: browser.isLoading,
                    isAudioMuted: browser.isMuted
                )
            }
            panelCancellables[panel.id] = cancellable
        } else if tracksTerminalTitle, let terminal = panel as? TerminalPanel {
            let cancellable = terminal.$title
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak terminal] _ in
                    guard let self, let terminal, let tabId = self.surfaceId(forPanelId: terminal.id) else { return }
                    self.bonsplitController.updateTab(tabId, title: terminal.displayTitle)
                }
            panelCancellables[panel.id] = cancellable
        }
    }

    // MARK: - Visibility

    private func applyVisibilityToAllPanels() {
        for panel in panels.values { applyVisibility(to: panel) }
    }

    private func applyVisibility(to panel: any Panel) {
        guard let terminal = panel as? TerminalPanel else { return }
        if isVisibleInUI {
            terminal.hostedView.setVisibleInUI(true)
            TerminalWindowPortalRegistry.updateEntryVisibility(for: terminal.hostedView, visibleInUI: true)
        } else {
            terminal.unfocus()
            terminal.hostedView.setVisibleInUI(false)
            TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
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
            if let panel = panels.removeValue(forKey: panelId) {
                panel.close()
            }
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
        panelCancellables.values.forEach { $0.cancel() }
        panelCancellables.removeAll()
    }

    private func cancelConfigurationTasks() {
        configurationLoadGeneration += 1
        configurationIdentityGeneration += 1
        configurationLoadTask?.cancel()
        configurationIdentityTask?.cancel()
        configurationLoadTask = nil
        configurationIdentityTask = nil
    }

    private func startConfigurationLoad(replacingPanels: Bool) {
        configurationLoadGeneration += 1
        let generation = configurationLoadGeneration
        let rootDirectory = currentBaseDirectory()
        configurationIdentityTask?.cancel()
        configurationLoadTask?.cancel()
        configurationLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.loadConfigurationSnapshot(rootDirectory: rootDirectory)
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
        guard lastLoadedConfigIdentity != current else { return }
        reload()
    }

    private nonisolated static func loadConfigurationSnapshot(rootDirectory: String?) -> DockConfigurationLoadResult {
        do {
            return .resolved(try resolve(rootDirectory: rootDirectory))
        } catch {
            return .failed(
                identity: configIdentity(rootDirectory: rootDirectory),
                message: error.localizedDescription
            )
        }
    }

    private func applyConfigurationLoadResult(
        _ result: DockConfigurationLoadResult,
        generation: Int,
        replacingPanels: Bool
    ) {
        guard generation == configurationLoadGeneration else { return }
        configurationLoadTask = nil
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
            let shouldSeed = replacingPanels || panels.isEmpty || !hasAppliedConfigurationSeed
            if shouldSeed {
                seed(definitions: resolution.controls, baseDirectory: resolution.baseDirectory)
                hasAppliedConfigurationSeed = true
            }
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
                guard bonsplitController.splitPane(
                    sourcePaneId,
                    orientation: .vertical,
                    withTab: newTab,
                    insertFirst: false,
                    initialDividerPosition: divider
                ) != nil else {
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
                target = try Self.preferredEditableConfigURL(rootDirectory: currentBaseDirectory())
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        Task { [weak self] in
            let result: (target: URL?, errorMessage: String?) = await Task.detached(priority: .userInitiated) {
                do {
                    try Self.prepareEditableConfig(at: target)
                    return (target, nil)
                } catch {
                    return (nil, error.localizedDescription)
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
