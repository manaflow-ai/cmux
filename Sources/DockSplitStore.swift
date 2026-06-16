import AppKit
import Bonsplit
import Combine
import CmuxTerminal
import CmuxTerminalEngine
import SwiftUI

/// The kind of surface a Dock pane hosts. The Dock reuses the main-area panel
/// system, so it supports the same first-class pane kinds: terminals and
/// browsers.
enum DockSurfaceKind: String, Codable, Equatable, Sendable {
    case terminal
    case browser
}

/// A single Dock control loaded from `dock.json`.
///
/// Back-compat: existing terminal-only configs omit `type`/`url` and require
/// `command`; those decode unchanged as `.terminal` entries. New configs may add
/// `"type": "browser"` with a `url` to seed a browser pane.
struct DockControlDefinition: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let kind: DockSurfaceKind
    let command: String?
    let url: String?
    let cwd: String?
    let height: Double?
    let env: [String: String]

    init(
        id: String,
        title: String,
        kind: DockSurfaceKind = .terminal,
        command: String? = nil,
        url: String? = nil,
        cwd: String? = nil,
        height: Double? = nil,
        env: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.command = command
        self.url = url
        self.cwd = cwd
        self.height = height
        self.env = env
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case type
        case command
        case url
        case cwd
        case height
        case env
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let normalizedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: String(localized: "dock.error.blankControlID", defaultValue: "Dock control id must not be blank.")
            )
        }

        let resolvedKind: DockSurfaceKind
        if let rawType = try container.decodeIfPresent(String.self, forKey: .type)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawType.isEmpty {
            guard let parsed = DockSurfaceKind(rawValue: rawType) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: String(localized: "dock.error.unknownControlType", defaultValue: "Dock control type must be terminal or browser.")
                )
            }
            resolvedKind = parsed
        } else {
            resolvedKind = .terminal
        }

        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? rawID
        let normalizedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedCommand = try container.decodeIfPresent(String.self, forKey: .command)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = try container.decodeIfPresent(String.self, forKey: .url)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch resolvedKind {
        case .terminal:
            guard let normalizedCommand, !normalizedCommand.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .command,
                    in: container,
                    debugDescription: String(localized: "dock.error.blankControlCommand", defaultValue: "Dock control command must not be blank.")
                )
            }
            command = normalizedCommand
            url = nil
        case .browser:
            guard let normalizedURL, !normalizedURL.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url,
                    in: container,
                    debugDescription: String(localized: "dock.error.blankControlURL", defaultValue: "Dock browser control url must not be blank.")
                )
            }
            url = normalizedURL
            command = nil
        }

        id = normalizedID
        title = normalizedTitle.isEmpty ? normalizedID : normalizedTitle
        kind = resolvedKind
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        switch kind {
        case .terminal:
            // Terminal entries are encoded exactly as the legacy schema (no
            // `type` key) so existing project-config trust fingerprints stay
            // stable for unchanged configs.
            try container.encode(command ?? "", forKey: .command)
        case .browser:
            try container.encode(DockSurfaceKind.browser.rawValue, forKey: .type)
            try container.encode(url ?? "", forKey: .url)
        }
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(height, forKey: .height)
        if !env.isEmpty {
            try container.encode(env, forKey: .env)
        }
    }
}

struct DockConfigFile: Codable {
    let controls: [DockControlDefinition]
}

struct DockConfigResolution {
    let controls: [DockControlDefinition]
    let sourceURL: URL?
    let baseDirectory: String
    let isProjectSource: Bool
}

struct DockTrustRequest: Identifiable {
    var id: String { descriptor.fingerprint }
    let descriptor: CmuxActionTrustDescriptor
    let configPath: String
}

/// Hosts the Dock's own Bonsplit tree of `Panel`s — terminals and browsers —
/// rendered in the right sidebar with the same split machinery as the main
/// content area. Each workspace owns one instance via `Workspace.dockSplit`.
///
/// This is a lean parallel to `Workspace`'s main-area container: it owns its own
/// `BonsplitController`, panel registry, and `BonsplitDelegate`, reusing
/// `TerminalPanel`/`BrowserPanel` (so Dock browsers share the same browser stack
/// — cookies, profiles, devtools — as main-split browsers).
@MainActor
final class DockSplitStore: ObservableObject, BonsplitDelegate {
    let workspaceId: UUID
    let bonsplitController: BonsplitController

    @Published private(set) var sourceLabel: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var trustRequest: DockTrustRequest?
    @Published private(set) var isVisibleInUI: Bool = false

    private let baseDirectoryProvider: () -> String?
    private var panels: [UUID: any Panel] = [:]
    private var surfaceIdToPanelId: [TabID: UUID] = [:]
    private var panelCancellables: [UUID: AnyCancellable] = [:]
    private var hasLoadedConfiguration = false
    private var activeConfigURL: URL?
    private var resolvedBaseDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path

    init(workspaceId: UUID, baseDirectoryProvider: @escaping () -> String?) {
        self.workspaceId = workspaceId
        self.baseDirectoryProvider = baseDirectoryProvider
        self.bonsplitController = BonsplitController(configuration: Self.makeConfiguration())
        self.sourceLabel = String(localized: "dock.source.title", defaultValue: "Dock")
        self.bonsplitController.delegate = self
        // Drop the controller's default welcome tab so the root pane starts
        // empty and renders the in-app create affordance until config seeds it.
        for tabId in bonsplitController.allTabIds {
            _ = bonsplitController.closeTab(tabId)
        }
    }

    private static func makeConfiguration() -> BonsplitConfiguration {
        BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            tabBarVisibility: .always,
            appearance: .default
        )
    }

    // MARK: - Lookups

    func panel(for tabId: TabID) -> (any Panel)? {
        guard let panelId = surfaceIdToPanelId[tabId] else { return nil }
        return panels[panelId]
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
            ensureLoaded()
        }
        setVisibleInUI(shouldBeVisible)
    }

    func setVisibleInUI(_ visible: Bool) {
        guard isVisibleInUI != visible else { return }
        isVisibleInUI = visible
        applyVisibilityToAllPanels()
    }

    private func ensureLoaded() {
        guard !hasLoadedConfiguration else { return }
        hasLoadedConfiguration = true
        loadConfiguration()
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

    func noteKeyboardFocusIntent(window: NSWindow?) {
        AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)
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
        focus: Bool = true
    ) -> UUID? {
        ensureLoaded()
        guard let panel = makePanel(
            kind: kind,
            command: command,
            url: url,
            environment: environment,
            workingDirectory: workingDirectory ?? currentBaseDirectory()
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
        focus: Bool = true
    ) -> UUID? {
        ensureLoaded()
        guard let panel = makePanel(
            kind: kind,
            command: command,
            url: url,
            environment: environment,
            workingDirectory: workingDirectory ?? currentBaseDirectory()
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

        panels[panel.id] = panel
        let newTab = Bonsplit.Tab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: tabKindRaw(kind),
            isDirty: panel.isDirty,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = panel.id
        guard bonsplitController.splitPane(sourcePaneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: panel.id)
            panel.close()
            return nil
        }
        installSubscription(for: panel, tracksTerminalTitle: true)
        applyVisibility(to: panel)
        if focus { focusPanel(panel.id) }
        return panel.id
    }

    /// Resolves a Dock pane for `surface.create --placement dock`: the requested
    /// pane if it exists in the Dock tree, else the focused/first Dock pane.
    /// Ensures config is loaded so the Dock always has at least its root pane.
    func resolvePane(requestedPaneID: UUID?) -> PaneID? {
        ensureLoaded()
        if let requestedPaneID,
           let pane = bonsplitController.allPaneIds.first(where: { $0.id == requestedPaneID }) {
            return pane
        }
        return bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first
    }

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
        workingDirectory: String
    ) -> (any Panel)? {
        switch kind {
        case .terminal:
            return makeTerminalPanel(
                command: command,
                useLoginShellWrapper: false,
                workingDirectory: workingDirectory,
                environment: environment,
                controlId: nil,
                controlTitle: nil
            )
        case .browser:
            guard BrowserAvailabilitySettings.isEnabled() else {
                if let url { _ = NSWorkspace.shared.open(url) }
                return nil
            }
            return BrowserPanel(workspaceId: workspaceId, initialURL: url)
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
            let url = def.url.flatMap { URL(string: $0) }
            return BrowserPanel(workspaceId: workspaceId, initialURL: url)
        }
    }

    private func makeTerminalPanel(
        command: String?,
        useLoginShellWrapper: Bool,
        workingDirectory: String,
        environment: [String: String],
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

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        reconcilePanels()
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        reconcilePanels()
    }

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {
        let surfaceKind: DockSurfaceKind = (kind == "browser") ? .browser : .terminal
        _ = newSurface(kind: surfaceKind, inPane: pane, focus: true)
    }

    /// Closes and removes any panels whose Bonsplit tab is no longer present in
    /// the tree (tab close, pane close, or merge).
    private func reconcilePanels() {
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

    private func currentBaseDirectory() -> String {
        if let directory = baseDirectoryProvider(), !directory.isEmpty {
            return directory
        }
        return resolvedBaseDirectory
    }

    // MARK: - Config loading

    func reload() {
        removeAllPanels()
        hasLoadedConfiguration = true
        loadConfiguration()
    }

    func trustAndReload() {
        if let trustRequest {
            CmuxActionTrust.shared.trust(trustRequest.descriptor)
        }
        reload()
    }

    private func removeAllPanels() {
        for tabId in bonsplitController.allTabIds {
            _ = bonsplitController.closeTab(tabId)
        }
        reconcilePanels()
        for panel in panels.values { panel.close() }
        panels.removeAll()
        surfaceIdToPanelId.removeAll()
        panelCancellables.values.forEach { $0.cancel() }
        panelCancellables.removeAll()
    }

    private func loadConfiguration() {
        errorMessage = nil
        trustRequest = nil
        activeConfigURL = nil
        let rootDirectory = baseDirectoryProvider()

        do {
            let resolution = try Self.resolve(rootDirectory: rootDirectory)
            activeConfigURL = resolution.sourceURL
            resolvedBaseDirectory = resolution.baseDirectory
            if let request = trustRequestIfNeeded(for: resolution) {
                sourceLabel = String(localized: "dock.source.project", defaultValue: "Project Dock")
                trustRequest = request
                return
            }
            sourceLabel = Self.sourceLabel(for: resolution)
            seed(definitions: resolution.controls, baseDirectory: resolution.baseDirectory)
        } catch {
            sourceLabel = String(localized: "dock.source.error", defaultValue: "Dock")
            errorMessage = error.localizedDescription
        }
    }

    /// Seeds the Dock tree from config. The legacy config is a flat list, so it
    /// seeds a vertical stack (each entry split below the previous) to mirror the
    /// Dock's prior top-to-bottom layout; users can then re-tile in-app.
    private func seed(definitions: [DockControlDefinition], baseDirectory: String) {
        guard !definitions.isEmpty else { return }
        let rootPaneId = bonsplitController.allPaneIds.first
        var previousPanelId: UUID?
        for definition in definitions {
            guard let panel = makePanel(for: definition, baseDirectory: baseDirectory) else { continue }
            // Config terminals carry a user-supplied title; keep it static
            // (don't track the live process title) to match Dock's prior look.
            let tracksTitle = definition.kind == .browser

            if let previousPanelId, let sourcePaneId = paneId(forPanelId: previousPanelId) {
                panels[panel.id] = panel
                let newTab = Bonsplit.Tab(
                    title: definition.title,
                    icon: panel.displayIcon,
                    kind: tabKindRaw(definition.kind),
                    isDirty: panel.isDirty,
                    isPinned: false
                )
                surfaceIdToPanelId[newTab.id] = panel.id
                guard bonsplitController.splitPane(sourcePaneId, orientation: .vertical, withTab: newTab, insertFirst: false) != nil else {
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
        do {
            let target: URL
            if let activeConfigURL {
                target = activeConfigURL
            } else {
                target = try Self.preferredEditableConfigURL(rootDirectory: baseDirectoryProvider())
            }
            if !FileManager.default.fileExists(atPath: target.path) {
                try Self.writeTemplate(to: target)
            }
            NSWorkspace.shared.open(target)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Config resolution (statics)

    private static func resolve(rootDirectory: String?) throws -> DockConfigResolution {
        if let projectURL = projectConfigURL(rootDirectory: rootDirectory) {
            return try loadConfig(
                from: projectURL,
                baseDirectory: projectBaseDirectory(for: projectURL),
                isProjectSource: true
            )
        }

        let globalURL = globalConfigURL()
        if FileManager.default.fileExists(atPath: globalURL.path) {
            return try loadConfig(
                from: globalURL,
                baseDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                isProjectSource: false
            )
        }

        return DockConfigResolution(
            controls: [],
            sourceURL: nil,
            baseDirectory: rootDirectory.flatMap(existingDirectory) ?? FileManager.default.homeDirectoryForCurrentUser.path,
            isProjectSource: false
        )
    }

    private static func loadConfig(
        from url: URL,
        baseDirectory: String,
        isProjectSource: Bool
    ) throws -> DockConfigResolution {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(DockConfigFile.self, from: data)
        var seen = Set<String>()
        for control in file.controls {
            guard seen.insert(control.id).inserted else {
                throw NSError(
                    domain: "cmux.dock",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "dock.error.duplicateControl",
                            defaultValue: "Dock control ids must be unique."
                        )
                    ]
                )
            }
        }
        return DockConfigResolution(
            controls: file.controls,
            sourceURL: url,
            baseDirectory: baseDirectory,
            isProjectSource: isProjectSource
        )
    }

    private static func sourceLabel(for resolution: DockConfigResolution) -> String {
        if resolution.sourceURL == nil {
            return String(localized: "dock.source.title", defaultValue: "Dock")
        }
        return resolution.isProjectSource
            ? String(localized: "dock.source.project", defaultValue: "Project Dock")
            : String(localized: "dock.source.global", defaultValue: "Global Dock")
    }

    private static func projectConfigURL(rootDirectory: String?) -> URL? {
        guard let rootDirectory = rootDirectory.flatMap(existingDirectory) else { return nil }
        var candidate = URL(fileURLWithPath: rootDirectory, isDirectory: true)
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        while true {
            let configURL = candidate
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent("dock.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: configURL.path) {
                return configURL
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path || candidate.path == homePath {
                return nil
            }
            candidate = parent
        }
    }

    private static func projectBaseDirectory(for configURL: URL) -> String {
        let cmuxDirectory = configURL.deletingLastPathComponent()
        return cmuxDirectory.deletingLastPathComponent().path
    }

    private static func globalConfigURL() -> URL {
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1",
           let testPath = ProcessInfo.processInfo.environment["CMUX_UI_TEST_DOCK_CONFIG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !testPath.isEmpty {
            return URL(fileURLWithPath: testPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/dock.json", isDirectory: false)
    }

    private static func preferredEditableConfigURL(rootDirectory: String?) throws -> URL {
        if let rootDirectory = rootDirectory.flatMap(existingDirectory) {
            return URL(fileURLWithPath: rootDirectory, isDirectory: true)
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent("dock.json", isDirectory: false)
        }
        return globalConfigURL()
    }

    private static func existingDirectory(_ rawPath: String) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue ? expanded : (expanded as NSString).deletingLastPathComponent
    }

    private static func writeTemplate(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = DockConfigFile(controls: [
            DockControlDefinition(
                id: "git",
                title: "Git",
                command: "lazygit",
                height: 300
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
    }

    private static func trustDescriptor(for resolution: DockConfigResolution) -> CmuxActionTrustDescriptor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(DockConfigFile(controls: resolution.controls))) ?? Data()
        let commandFingerprint = String(data: data, encoding: .utf8) ?? ""
        return CmuxActionTrustDescriptor(
            actionID: "cmux.dock",
            kind: "dockControls",
            command: commandFingerprint,
            target: "rightSidebarDock",
            workspaceCommand: nil,
            configPath: resolution.sourceURL.map { canonicalPath($0.path) },
            projectRoot: canonicalPath(resolution.baseDirectory),
            iconFingerprint: nil
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private static func resolvedWorkingDirectory(_ cwd: String?, baseDirectory: String) -> String {
        guard let cwd, !cwd.isEmpty else { return baseDirectory }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseDirectory as NSString).appendingPathComponent(cwd)
    }

    private static func shellStartupScript(command: String, workingDirectory: String) -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-dock-control-\(UUID().uuidString.lowercased()).sh"
        )
        let encodedCommand = Data(command.utf8).base64EncodedString()
        let encodedWorkingDirectory = Data(workingDirectory.utf8).base64EncodedString()
        let body = """
        #!/bin/sh
        cmux_dock_decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
        cmux_dock_login_shell() {
          cmux_dock_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
          cmux_dock_ds_shell="$(dscl . -read "/Users/$cmux_dock_user" UserShell 2>/dev/null | awk '{print $2; exit}')"
          if [ -n "$cmux_dock_ds_shell" ] && [ -x "$cmux_dock_ds_shell" ]; then printf '%s\\n' "$cmux_dock_ds_shell"
          elif [ -n "${SHELL:-}" ] && [ -x "${SHELL:-}" ]; then printf '%s\\n' "$SHELL"
          else printf '%s\\n' /bin/sh; fi
        }
        cmux_dock_command="$(cmux_dock_decode '\(encodedCommand)')"
        cmux_dock_working_directory="$(cmux_dock_decode '\(encodedWorkingDirectory)')"
        cmux_dock_shell="$(cmux_dock_login_shell)"
        cmux_dock_bundle_bin=""
        if [ -n "${CMUX_BUNDLED_CLI_PATH:-}" ]; then cmux_dock_bundle_bin="$(dirname "$CMUX_BUNDLED_CLI_PATH")"; fi
        export SHELL="$cmux_dock_shell"
        rm -f -- "$0" 2>/dev/null || true
        case "$(basename "$cmux_dock_shell")" in
          fish)
            CMUX_DOCK_BUNDLE_BIN="$cmux_dock_bundle_bin" CMUX_DOCK_START_COMMAND="$cmux_dock_command" CMUX_DOCK_START_DIRECTORY="$cmux_dock_working_directory" "$cmux_dock_shell" -l -c 'if test -n "$CMUX_DOCK_BUNDLE_BIN"; and not contains -- "$CMUX_DOCK_BUNDLE_BIN" $PATH; set -gx PATH "$CMUX_DOCK_BUNDLE_BIN" $PATH; end; if test -n "$CMUX_DOCK_START_DIRECTORY"; cd "$CMUX_DOCK_START_DIRECTORY"; end; eval "$CMUX_DOCK_START_COMMAND"'
            ;;
          *) CMUX_DOCK_BUNDLE_BIN="$cmux_dock_bundle_bin" CMUX_DOCK_START_COMMAND="$cmux_dock_command" CMUX_DOCK_START_DIRECTORY="$cmux_dock_working_directory" "$cmux_dock_shell" -lc 'if [ -n "${CMUX_DOCK_BUNDLE_BIN:-}" ]; then case ":${PATH:-}:" in *":$CMUX_DOCK_BUNDLE_BIN:"*) ;; *) PATH="$CMUX_DOCK_BUNDLE_BIN${PATH:+:$PATH}"; export PATH ;; esac; fi; cd "$CMUX_DOCK_START_DIRECTORY" 2>/dev/null || true; eval "$CMUX_DOCK_START_COMMAND"'
            ;;
        esac
        printf '\\n'
        exec "$cmux_dock_shell" -l
        """
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            return "/bin/sh"
        }
    }
}
