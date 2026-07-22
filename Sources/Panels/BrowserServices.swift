import AppKit
import CmuxBrowser
import Foundation
import WebKit

/// Process-wide browser services owned by the app composition root and injected
/// through window, workspace, and panel owners.
@MainActor
final class BrowserServices {
    typealias ExtensionDirectoryRemover = @Sendable (URL) -> Void

    private struct PendingWebExtensionNavigation {
        let ownerID: UUID
        let profileID: UUID
        let execute: @MainActor () -> Void
    }

    private let extensionDirectory: URL
    private let extensionDirectoryRemover: ExtensionDirectoryRemover
    private var webExtensionsManagerStorage: [UUID: AnyObject] = [:]
    private var pendingWebExtensionNavigations: [UUID: PendingWebExtensionNavigation] = [:]
    private var pendingWebExtensionNavigationIDsByOwner: [UUID: UUID] = [:]
    private var registeredPanelProfileIDs: [UUID: UUID] = [:]
    private var profileDeletionObserver: NSObjectProtocol?

    var registeredBrowserPanelCount: Int { registeredPanelProfileIDs.count }

    init(
        extensionDirectory: URL? = nil,
        extensionDirectoryRemover: @escaping ExtensionDirectoryRemover = { directory in
            try? FileManager.default.removeItem(at: directory)
        }
    ) {
        self.extensionDirectory = extensionDirectory ?? Self.defaultExtensionDirectory
        self.extensionDirectoryRemover = extensionDirectoryRemover
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
        observeWebExtensionRuntime(manager.profileRuntime)
        return manager
    }

    @available(macOS 15.4, *)
    private func observeWebExtensionRuntime(_ runtime: BrowserWebExtensionProfileRuntime) {
        runtime.setNavigationUpdateHandler { [weak self] update in
            guard let self else { return }
            switch update {
            case .navigationReleased(let intent, _):
                self.releaseWebExtensionNavigation(intent)
            case .navigationCancelled(let intentID):
                self.removeWebExtensionNavigation(intentID)
            case .phaseChanged, .actionChanged, .snapshotInvalidated, .permissionRequested:
                break
            }
        }
    }

    @available(macOS 15.4, *)
    func installWebExtensionsManagerForTesting(
        _ manager: BrowserWebExtensionsManager,
        profileID: UUID
    ) {
        precondition(manager.profileRuntime.profileID == profileID)
        if let previous = webExtensionsManagerStorage[profileID] as? BrowserWebExtensionsManager {
            previous.profileRuntime.setNavigationUpdateHandler(nil)
        }
        webExtensionsManagerStorage[profileID] = manager
        observeWebExtensionRuntime(manager.profileRuntime)
    }

    func scheduleWebExtensionNavigation(
        ownerID: UUID,
        profileID: UUID,
        targetURL: URL?,
        reason: BrowserWebExtensionNavigationReason,
        execute: @escaping @MainActor () -> Void
    ) {
        cancelWebExtensionNavigation(ownerID: ownerID)
        guard #available(macOS 15.4, *) else {
            execute()
            return
        }
        let manager = webExtensionsManager(for: profileID)
        let intent = BrowserWebExtensionNavigationIntent(
            profileID: profileID,
            targetURL: targetURL,
            reason: reason
        )
        pendingWebExtensionNavigations[intent.id] = PendingWebExtensionNavigation(
            ownerID: ownerID,
            profileID: profileID,
            execute: execute
        )
        pendingWebExtensionNavigationIDsByOwner[ownerID] = intent.id
        guard manager.profileRuntime.enqueueNavigation(intent) else {
            removeWebExtensionNavigation(intent.id)
            execute()
            return
        }
        manager.startLoading()
    }

    func cancelWebExtensionNavigation(ownerID: UUID) {
        guard let intentID = pendingWebExtensionNavigationIDsByOwner.removeValue(forKey: ownerID) else {
            return
        }
        guard let pending = pendingWebExtensionNavigations.removeValue(forKey: intentID) else { return }
        if #available(macOS 15.4, *),
           let manager = webExtensionsManagerStorage[pending.profileID] as? BrowserWebExtensionsManager {
            _ = manager.profileRuntime.cancelNavigation(id: intentID)
        }
    }

    func isWebExtensionNavigationPending(ownerID: UUID) -> Bool {
        pendingWebExtensionNavigationIDsByOwner[ownerID] != nil
    }

    private func releaseWebExtensionNavigation(_ intent: BrowserWebExtensionNavigationIntent) {
        guard let pending = pendingWebExtensionNavigations.removeValue(forKey: intent.id),
              pending.profileID == intent.profileID,
              pendingWebExtensionNavigationIDsByOwner[pending.ownerID] == intent.id else {
            return
        }
        pendingWebExtensionNavigationIDsByOwner.removeValue(forKey: pending.ownerID)
        pending.execute()
    }

    private func removeWebExtensionNavigation(_ intentID: UUID) {
        guard let pending = pendingWebExtensionNavigations.removeValue(forKey: intentID) else { return }
        if pendingWebExtensionNavigationIDsByOwner[pending.ownerID] == intentID {
            pendingWebExtensionNavigationIDsByOwner.removeValue(forKey: pending.ownerID)
        }
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
        let navigationIDs = pendingWebExtensionNavigations.compactMap { id, pending in
            pending.profileID == profileID ? id : nil
        }
        for id in navigationIDs {
            removeWebExtensionNavigation(id)
        }
        if #available(macOS 15.4, *),
           let manager = managerObject as? BrowserWebExtensionsManager {
            manager.profileRuntime.setNavigationUpdateHandler(nil)
            await manager.shutdownAndRemoveDirectory()
        } else {
            extensionDirectoryRemover(directory)
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

    func webExtensionUpdates(
        profileID: UUID,
        panelID: UUID
    ) -> AsyncStream<BrowserWebExtensionUpdate> {
        guard #available(macOS 15.4, *) else {
            return AsyncStream { $0.finish() }
        }
        let manager = webExtensionsManager(for: profileID)
        manager.startLoading()
        return manager.profileRuntime.presentationUpdates(for: panelID)
    }

    func prepareWebExtensionInstall(
        from source: URL,
        profileID: UUID
    ) async throws -> BrowserWebExtensionInstallPreview {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        return try await webExtensionsManager(for: profileID).prepareInstall(from: source)
    }

    func prepareWebExtensionInstall(
        _ entry: BrowserWebExtensionCatalogEntry,
        profileID: UUID
    ) async throws -> BrowserWebExtensionInstallPreview {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        return try await webExtensionsManager(for: profileID).prepareCatalogInstall(entry)
    }

    func cancelPreparedWebExtensionInstall(id: UUID, profileID: UUID) async {
        guard #available(macOS 15.4, *) else { return }
        await webExtensionsManager(for: profileID).cancelPreparedInstall(id: id)
    }

    func confirmPreparedWebExtensionInstall(
        id: UUID,
        grantedOptionalPermissions: Set<String>,
        grantedOptionalHosts: Set<String>,
        profileID: UUID
    ) async throws -> BrowserWebExtensionInstallReceipt {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        return try await webExtensionsManager(for: profileID).confirmPreparedInstall(
            id: id,
            grantedOptionalPermissions: grantedOptionalPermissions,
            grantedOptionalHosts: grantedOptionalHosts
        )
    }

    func setWebExtensionEnabled(
        _ isEnabled: Bool,
        managementID: String,
        profileID: UUID
    ) async throws {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        try await webExtensionsManager(for: profileID).setExtensionEnabled(
            managementID: managementID,
            isEnabled: isEnabled
        )
    }

    func removeWebExtension(managementID: String, profileID: UUID) async throws {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        try await webExtensionsManager(for: profileID).removeExtension(managementID: managementID)
    }

    func revokeWebExtensionOptionalPermissions(
        managementID: String,
        profileID: UUID
    ) async throws {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        try await webExtensionsManager(for: profileID).revokeOptionalPermissions(
            managementID: managementID
        )
    }

    func prepareWebExtensionUpdate(
        managementID: String,
        profileID: UUID
    ) async throws -> BrowserWebExtensionInstallPreview {
        guard #available(macOS 15.4, *) else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        return try await webExtensionsManager(for: profileID).prepareUpdate(
            managementID: managementID
        )
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
            },
            closePanel: { [weak workspace] panelID in
                workspace?.closePanel(panelID, force: true) ?? false
            },
            isPanelPinned: { [weak workspace] panelID in
                workspace?.isPanelPinned(panelID) ?? false
            },
            setPanelPinned: { [weak workspace] panelID, pinned in
                guard let workspace, workspace.panels[panelID] != nil else { return false }
                workspace.setPanelPinned(panelId: panelID, pinned: pinned)
                return workspace.isPanelPinned(panelID) == pinned
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
            },
            closePanel: { [weak dock] panelID in
                dock?.closePanel(panelID, force: true) ?? false
            },
            isPanelPinned: { [weak dock] panelID in
                guard let dock,
                      let tabID = dock.surfaceId(forPanelId: panelID) else { return false }
                return dock.bonsplitController.tab(tabID)?.isPinned ?? false
            },
            setPanelPinned: { [weak dock] panelID, pinned in
                guard let dock,
                      let tabID = dock.surfaceId(forPanelId: panelID),
                      dock.bonsplitController.tab(tabID) != nil else { return false }
                dock.bonsplitController.updateTab(tabID, isPinned: pinned)
                return dock.bonsplitController.tab(tabID)?.isPinned == pinned
            }
        )
    }

    func unregisterBrowserPanel(id: UUID) {
        cancelWebExtensionNavigation(ownerID: id)
        guard #available(macOS 15.4, *),
              let profileID = registeredPanelProfileIDs.removeValue(forKey: id),
              let manager = webExtensionsManagerStorage[profileID] as? BrowserWebExtensionsManager else {
            return
        }
        manager.unregister(panelID: id)
        releaseWebExtensionsManagerIfUnused(profileID)
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
        releaseWebExtensionsManagerIfUnused(previousProfileID)
        let manager = webExtensionsManager(for: panel.profileID)
        manager.register(
            panel: panel,
            ownerID: owner.id,
            activePanelID: owner.activePanelID,
            focusPriority: owner.focusPriority,
            focusPanel: owner.focusPanel,
            orderedPanelIDs: owner.orderedPanelIDs,
            createTab: owner.createTab,
            closePanel: owner.closePanel,
            isPanelPinned: owner.isPanelPinned,
            setPanelPinned: owner.setPanelPinned
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
        createTab: @escaping @MainActor (Int, Bool, Bool) -> BrowserPanel?,
        closePanel: @escaping @MainActor (UUID) -> Bool,
        isPanelPinned: @escaping @MainActor (UUID) -> Bool,
        setPanelPinned: @escaping @MainActor (UUID, Bool) -> Bool
    ) {
        guard #available(macOS 15.4, *) else { return }
        if let previousProfileID = registeredPanelProfileIDs[panel.id],
           let previousManager = webExtensionsManagerStorage[previousProfileID] as? BrowserWebExtensionsManager {
            let previousOwnerID = previousManager.registrationOwner(for: panel.id)?.id
            if previousProfileID != panel.profileID || previousOwnerID != ownerID {
                previousManager.unregister(panelID: panel.id)
                if previousProfileID != panel.profileID {
                    registeredPanelProfileIDs.removeValue(forKey: panel.id)
                    releaseWebExtensionsManagerIfUnused(previousProfileID)
                }
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
            createTab: createTab,
            closePanel: closePanel,
            isPanelPinned: isPanelPinned,
            setPanelPinned: setPanelPinned
        )
        manager.startLoading()
    }

    @available(macOS 15.4, *)
    private func releaseWebExtensionsManagerIfUnused(_ profileID: UUID) {
        let defaultProfileID = BrowserProfileStore.shared.builtInDefaultProfileID
        guard profileID != defaultProfileID,
              !registeredPanelProfileIDs.values.contains(profileID),
              let manager = webExtensionsManagerStorage.removeValue(forKey: profileID)
                as? BrowserWebExtensionsManager else {
            return
        }
        BrowserPrewarmedWebViewPool.shared.discard(
            profileID: profileID,
            browserServices: self,
            reason: "profile-runtime-released"
        )
        let pendingIDs = pendingWebExtensionNavigations.compactMap { id, pending in
            pending.profileID == profileID ? id : nil
        }
        for id in pendingIDs {
            _ = manager.profileRuntime.cancelNavigation(id: id)
            removeWebExtensionNavigation(id)
        }
        manager.profileRuntime.setNavigationUpdateHandler(nil)
        manager.shutdown()
    }

#if DEBUG
    @available(macOS 15.4, *)
    func hasRetainedWebExtensionsManagerForTesting(profileID: UUID) -> Bool {
        webExtensionsManagerStorage[profileID] is BrowserWebExtensionsManager
    }
#endif

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
