import AppKit
import Foundation
import WebKit

/// Process-wide browser services owned by the app composition root and injected
/// through window, workspace, and panel owners.
@MainActor
final class BrowserServices {
    private let extensionDirectory: URL
    private var webExtensionsManagerStorage: [UUID: AnyObject] = [:]
    private var registeredPanelProfileIDs: [UUID: UUID] = [:]
    private var profileDeletionObserver: NSObjectProtocol?

    var registeredBrowserPanelCount: Int { registeredPanelProfileIDs.count }

    init(extensionDirectory: URL? = nil) {
        self.extensionDirectory = extensionDirectory ?? Self.defaultExtensionDirectory
        profileDeletionObserver = NotificationCenter.default.addObserver(
            forName: BrowserProfileStore.profileDidDeleteNotification,
            object: BrowserProfileStore.shared,
            queue: .main
        ) { [weak self] notification in
            guard let profileID = notification.userInfo?[BrowserProfileStore.profileIDNotificationKey] as? UUID else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.profileDidDelete(profileID)
            }
        }
    }

    deinit {
        if let profileDeletionObserver {
            NotificationCenter.default.removeObserver(profileDeletionObserver)
        }
    }

    @available(macOS 15.4, *)
    var webExtensionsManager: BrowserWebExtensionsManager? {
        webExtensionsManager(for: BrowserProfileStore.shared.builtInDefaultProfileID)
    }

    @available(macOS 15.4, *)
    func webExtensionsManager(for profileID: UUID) -> BrowserWebExtensionsManager {
        if let manager = webExtensionsManagerStorage[profileID] as? BrowserWebExtensionsManager {
            return manager
        }
        let defaultProfileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let manager = BrowserWebExtensionsManager(
            directory: Self.extensionDirectory(
                for: profileID,
                defaultProfileID: defaultProfileID,
                root: extensionDirectory
            ),
            controllerIdentifier: profileID == defaultProfileID ? nil : profileID,
            websiteDataStore: BrowserProfileStore.shared.websiteDataStore(for: profileID),
            profileID: profileID
        )
        webExtensionsManagerStorage[profileID] = manager
        return manager
    }

    private func profileDidDelete(_ profileID: UUID) async {
        guard profileID != BrowserProfileStore.shared.builtInDefaultProfileID else { return }
        registeredPanelProfileIDs = registeredPanelProfileIDs.filter { $0.value != profileID }
        let directory = Self.extensionDirectory(
            for: profileID,
            defaultProfileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            root: extensionDirectory
        )
        let managerObject = webExtensionsManagerStorage.removeValue(forKey: profileID)
        if #available(macOS 15.4, *),
           let manager = managerObject as? BrowserWebExtensionsManager {
            await manager.shutdownAndRemoveDirectory()
        } else {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Starts browser-wide services before restored browser panels are created.
    /// Extension loading waits until a WebView exists so WebKit can attach
    /// persisted declarative rules to its user-content controller.
    func start() {
        BrowserSystemProxyWatcher.shared.startObserving()
        BrowserPrewarmedWebViewPool.shared.configure(browserServices: self)
    }

    func webExtensionsPresentationSnapshot(
        for panelID: UUID,
        profileID: UUID
    ) async -> BrowserWebExtensionsPresentationSnapshot {
        guard #available(macOS 15.4, *) else {
            return .unsupported
        }
        let webExtensionsManager = webExtensionsManager(for: profileID)
        webExtensionsManager.startLoading()
        await webExtensionsManager.waitUntilPresentationReady()
        return webExtensionsManager.presentationSnapshot(for: panelID)
    }

    /// Waits for the profile's extension contexts to be ready before the
    /// profile's first page navigation can race content-script injection.
    func waitUntilWebExtensionsLoaded(for profileID: UUID) async {
        guard #available(macOS 15.4, *) else { return }
        let webExtensionsManager = webExtensionsManager(for: profileID)
        webExtensionsManager.startLoading()
        await webExtensionsManager.waitUntilLoaded()
    }

    func installWebExtension(
        from source: URL,
        profileID: UUID
    ) async throws -> BrowserWebExtensionInstallReceipt {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        return try await webExtensionsManager(for: profileID).installExtension(from: source)
    }

    func installWebExtension(
        _ entry: BrowserWebExtensionCatalogEntry,
        profileID: UUID
    ) async throws -> BrowserWebExtensionInstallReceipt {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        return try await webExtensionsManager(for: profileID).installCatalogExtension(entry)
    }

    func setWebExtensionToolbarActionPinned(
        _ isPinned: Bool,
        uniqueIdentifier: String,
        profileID: UUID
    ) async -> Bool {
        guard #available(macOS 15.4, *) else { return false }
        do {
            try await webExtensionsManager(for: profileID).setToolbarActionPinned(
                isPinned,
                uniqueIdentifier: uniqueIdentifier
            )
            return true
        } catch {
#if DEBUG
            let nsError = error as NSError
            cmuxDebugLog(
                "browser.extensions.toolbar-pin-failed id=\(uniqueIdentifier) " +
                "pinned=\(isPinned ? 1 : 0) domain=\(nsError.domain) code=\(nsError.code)"
            )
#endif
            return false
        }
    }

    func webExtensionDiagnostics(
        profileID: UUID,
        matching identifier: String? = nil
    ) async throws -> [String: Any] {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        let webExtensionsManager = webExtensionsManager(for: profileID)
        webExtensionsManager.startLoading()
        await webExtensionsManager.waitUntilPresentationReady()
        var payload = webExtensionsManager.diagnosticPayload(matching: identifier)
        payload["profile_id"] = profileID.uuidString
        return payload
    }

    func webExtensionWebViews(
        profileID: UUID,
        matching identifier: String? = nil
    ) async throws -> [String: Any] {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        let webExtensionsManager = webExtensionsManager(for: profileID)
        webExtensionsManager.startLoading()
        await webExtensionsManager.waitUntilPresentationReady()
        var payload = webExtensionsManager.webViewPayload(matching: identifier)
        payload["profile_id"] = profileID.uuidString
        return payload
    }

    @available(macOS 15.4, *)
    func webExtensionPageConfiguration(
        for url: URL,
        profileID: UUID
    ) -> (baseURL: URL, configuration: WKWebViewConfiguration)? {
        webExtensionsManager(for: profileID).pageConfiguration(for: url)
    }

    func performWebExtensionAction(
        matching identifier: String,
        panelID: UUID,
        profileID: UUID
    ) async throws -> [String: Any] {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        let webExtensionsManager = webExtensionsManager(for: profileID)
        webExtensionsManager.startLoading()
        await webExtensionsManager.waitUntilPresentationReady()
        var payload = try webExtensionsManager.performAction(
            matching: identifier,
            panelID: panelID
        )
        payload["profile_id"] = profileID.uuidString
        return payload
    }

    func evaluateWebExtensionJavaScript(
        _ script: String,
        matching identifier: String,
        webViewIdentifier: String? = nil,
        profileID: UUID
    ) async throws -> [String: Any] {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        let webExtensionsManager = webExtensionsManager(for: profileID)
        webExtensionsManager.startLoading()
        await webExtensionsManager.waitUntilPresentationReady()
        var payload = try await webExtensionsManager.evaluateJavaScript(
            script,
            matching: identifier,
            webViewIdentifier: webViewIdentifier
        )
        payload["profile_id"] = profileID.uuidString
        return payload
    }

    func webExtensionConsole(
        matching identifier: String,
        profileID: UUID
    ) async throws -> [String: Any] {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        let webExtensionsManager = webExtensionsManager(for: profileID)
        webExtensionsManager.startLoading()
        await webExtensionsManager.waitUntilPresentationReady()
        var payload = try await webExtensionsManager.consolePayload(matching: identifier)
        payload["profile_id"] = profileID.uuidString
        return payload
    }

    func registerBrowserPanel(_ panel: BrowserPanel, workspace: Workspace) {
        registerBrowserPanel(
            panel,
            ownerID: workspace.id,
            activePanelID: { [weak workspace] in workspace?.focusedPanelId },
            focusPriority: { [weak workspace] in
                guard let workspace,
                      let manager = workspace.owningTabManager,
                      manager.selectedTabId == workspace.id,
                      let window = manager.window,
                      window.isKeyWindow else { return 0 }
                guard let responder = window.firstResponder,
                      let panelID = workspace.focusedPanelId,
                      let panel = workspace.panels[panelID],
                      panel.ownedFocusIntent(for: responder, in: window) != nil else {
                    return 1
                }
                return 2
            },
            focusPanel: { [weak workspace] panelID in workspace?.focusPanel(panelID) },
            orderedPanelIDs: { [weak workspace] in workspace?.orderedPanelIds ?? [] },
            createTab: { [weak workspace, weak panel] index, shouldBeActive, shouldAddToSelection in
                guard let workspace, let panel else { return nil }
                let previousFocusedPanelID = workspace.focusedPanelId
                let anchorPanelID = previousFocusedPanelID ?? panel.id
                guard let paneID = workspace.paneId(forPanelId: anchorPanelID),
                      let newPanel = workspace.newBrowserSurface(
                        inPane: paneID,
                        focus: shouldBeActive,
                        selectWhenNotFocused: shouldAddToSelection,
                        insertAtEnd: true,
                        preferredProfileID: panel.profileID
                      ) else { return nil }
                if index != NSNotFound {
                    _ = workspace.reorderSurface(
                        panelId: newPanel.id,
                        toIndex: index,
                        focus: shouldBeActive
                    )
                }
                if !shouldBeActive, let previousFocusedPanelID {
                    workspace.focusPanel(previousFocusedPanelID)
                }
                return newPanel
            }
        )
    }

    func registerBrowserPanel(_ panel: BrowserPanel, dock: DockSplitStore) {
        registerBrowserPanel(
            panel,
            ownerID: dock.webExtensionWindowID,
            activePanelID: { [weak dock] in dock?.focusedPanelId },
            focusPriority: { [weak dock] in
                guard let dock,
                      dock.isVisibleInUI,
                      let panelID = dock.focusedPanelId,
                      let panel = dock.panels[panelID],
                      let window = dock.panels.values
                        .compactMap({ ($0 as? BrowserPanel)?.webView.window })
                        .first(where: { $0.isKeyWindow }),
                      let responder = window.firstResponder,
                      panel.ownedFocusIntent(for: responder, in: window) != nil else {
                    return 0
                }
                return 2
            },
            focusPanel: { [weak dock] panelID in dock?.focusPanel(panelID) },
            orderedPanelIDs: { [weak dock] in
                guard let dock else { return [] }
                return dock.bonsplitController.allTabIds.compactMap { dock.panel(for: $0)?.id }
            },
            createTab: { [weak dock, weak panel] index, shouldBeActive, shouldAddToSelection in
                guard let dock, let panel else { return nil }
                let shouldFocus = shouldBeActive || shouldAddToSelection
                let previousSelection = shouldFocus ? nil : dock.focusedDockPaneSelection()
                let anchorPanelID = dock.focusedPanelId ?? panel.id
                guard let paneID = dock.paneId(forPanelId: anchorPanelID),
                      let newPanelID = dock.newSurface(
                        kind: .browser,
                        inPane: paneID,
                        focus: shouldFocus,
                        preferredProfileID: panel.profileID
                      ),
                      let newPanel = dock.browserPanel(for: newPanelID) else { return nil }
                if index != NSNotFound,
                   let tabID = dock.surfaceId(forPanelId: newPanelID) {
                    _ = dock.bonsplitController.reorderTab(tabID, toIndex: index)
                }
                if !shouldFocus {
                    dock.restoreDockPaneSelection(previousSelection)
                }
                return newPanel
            }
        )
    }

    func unregisterBrowserPanel(id: UUID) {
        guard #available(macOS 15.4, *),
              let profileID = registeredPanelProfileIDs.removeValue(forKey: id),
              let manager = webExtensionsManagerStorage[profileID] as? BrowserWebExtensionsManager else {
            return
        }
        manager.unregister(panelID: id)
    }

    func browserPanelProfileDidChange(_ panel: BrowserPanel) {
        guard #available(macOS 15.4, *),
              let previousProfileID = registeredPanelProfileIDs[panel.id],
              previousProfileID != panel.profileID,
              let previousManager = webExtensionsManagerStorage[previousProfileID] as? BrowserWebExtensionsManager,
              let owner = previousManager.registrationOwner(for: panel.id) else {
            return
        }
        previousManager.unregister(panelID: panel.id)
        registeredPanelProfileIDs[panel.id] = panel.profileID
        let manager = webExtensionsManager(for: panel.profileID)
        manager.register(
            panel: panel,
            ownerID: owner.id,
            activePanelID: owner.activePanelID,
            focusPriority: owner.focusPriority,
            focusPanel: owner.focusPanel,
            orderedPanelIDs: owner.orderedPanelIDs,
            createTab: owner.createTab
        )
        manager.startLoading()
    }

    @available(macOS 15.4, *)
    func webExtensionTabPropertiesDidChange(
        panelID: UUID,
        properties: WKWebExtension.TabChangedProperties
    ) {
        guard let profileID = registeredPanelProfileIDs[panelID],
              let manager = webExtensionsManagerStorage[profileID] as? BrowserWebExtensionsManager else {
            return
        }
        manager.tabPropertiesDidChange(panelID: panelID, properties: properties)
    }

    func browserPanelInternalPageDidChange(_ panel: BrowserPanel) {
        guard #available(macOS 15.4, *),
              let profileID = registeredPanelProfileIDs[panel.id],
              let manager = webExtensionsManagerStorage[profileID] as? BrowserWebExtensionsManager else {
            return
        }
        manager.tabVisibilityDidChange(panelID: panel.id)
    }

    func activateWebExtensionTab(panelID: UUID, previousPanelID: UUID?) {
        guard #available(macOS 15.4, *) else { return }
        let profileID = registeredPanelProfileIDs[panelID]
        let previousProfileID = previousPanelID.flatMap { registeredPanelProfileIDs[$0] }
        if let previousPanelID,
           let previousProfileID,
           previousPanelID != panelID,
           previousProfileID != profileID,
           let previousManager = webExtensionsManagerStorage[previousProfileID] as? BrowserWebExtensionsManager {
            previousManager.deactivateTab(panelID: previousPanelID)
        }
        guard let profileID,
              let manager = webExtensionsManagerStorage[profileID] as? BrowserWebExtensionsManager else {
            return
        }
        manager.activateTab(
            panelID: panelID,
            previousPanelID: previousProfileID == profileID ? previousPanelID : nil
        )
    }

    func browserWindowFocusDidChange() {
        guard #available(macOS 15.4, *) else { return }
        for manager in webExtensionsManagerStorage.values {
            (manager as? BrowserWebExtensionsManager)?.windowFocusDidChange()
        }
    }

    func webExtensionTabOrderDidChange(ownerID: UUID) {
        guard #available(macOS 15.4, *) else { return }
        for manager in webExtensionsManagerStorage.values {
            (manager as? BrowserWebExtensionsManager)?.synchronizeTabOrder(ownerID: ownerID)
        }
    }

    func performWebExtensionAction(
        uniqueIdentifier: String,
        in panel: BrowserPanel,
        anchorView: NSView?
    ) -> Bool {
        guard #available(macOS 15.4, *) else { return false }
        return webExtensionsManager(for: panel.profileID).performAction(
            uniqueIdentifier: uniqueIdentifier,
            in: panel,
            anchorView: anchorView
        )
    }

    private func registerBrowserPanel(
        _ panel: BrowserPanel,
        ownerID: UUID,
        activePanelID: @escaping @MainActor () -> UUID?,
        focusPriority: @escaping @MainActor () -> Int,
        focusPanel: @escaping @MainActor (UUID) -> Void,
        orderedPanelIDs: @escaping @MainActor () -> [UUID],
        createTab: @escaping @MainActor (Int, Bool, Bool) -> BrowserPanel?
    ) {
        guard #available(macOS 15.4, *) else { return }
        if let previousProfileID = registeredPanelProfileIDs[panel.id],
           let previousManager = webExtensionsManagerStorage[previousProfileID] as? BrowserWebExtensionsManager {
            let previousOwnerID = previousManager.registrationOwner(for: panel.id)?.id
            if previousProfileID != panel.profileID || previousOwnerID != ownerID {
                previousManager.unregister(panelID: panel.id)
            }
        }
        registeredPanelProfileIDs[panel.id] = panel.profileID
        let manager = webExtensionsManager(for: panel.profileID)
        manager.register(
            panel: panel,
            ownerID: ownerID,
            activePanelID: activePanelID,
            focusPriority: focusPriority,
            focusPanel: focusPanel,
            orderedPanelIDs: orderedPanelIDs,
            createTab: createTab
        )
        manager.startLoading()
    }

    nonisolated static func extensionDirectory(
        for profileID: UUID,
        defaultProfileID: UUID,
        root: URL
    ) -> URL {
        guard profileID != defaultProfileID else { return root }
        return root
            .appendingPathComponent(".profiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
    }

    private static var defaultExtensionDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CMUX_BROWSER_EXTENSIONS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/browser-extensions", isDirectory: true)
    }
}

struct BrowserWebExtensionInstallReceipt: Equatable, Sendable {
    let name: String
}

enum BrowserWebExtensionServiceError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        String(
            localized: "browser.extensions.unsupported",
            defaultValue: "Browser extensions require macOS 15.4 or later."
        )
    }
}
