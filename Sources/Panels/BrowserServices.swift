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

    init(extensionDirectory: URL? = nil) {
        self.extensionDirectory = extensionDirectory ?? Self.defaultExtensionDirectory
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
            controllerIdentifier: profileID == defaultProfileID ? nil : profileID
        )
        webExtensionsManagerStorage[profileID] = manager
        manager.startLoading()
        return manager
    }

    /// Starts browser-wide services before restored browser panels are created.
    func start() {
        BrowserSystemProxyWatcher.shared.startObserving()
        if #available(macOS 15.4, *) {
            webExtensionsManager?.startLoading()
        }
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
            focusPanel: { [weak workspace] panelID in workspace?.focusPanel(panelID) }
        )
    }

    func registerBrowserPanel(_ panel: BrowserPanel, dock: DockSplitStore) {
        registerBrowserPanel(
            panel,
            ownerID: dock.webExtensionWindowID,
            activePanelID: { [weak dock] in dock?.focusedPanelId },
            focusPanel: { [weak dock] panelID in dock?.focusPanel(panelID) }
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
        webExtensionsManager(for: panel.profileID).register(
            panel: panel,
            ownerID: owner.id,
            activePanelID: owner.activePanelID,
            focusPanel: owner.focusPanel
        )
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
        focusPanel: @escaping @MainActor (UUID) -> Void
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
        webExtensionsManager(for: panel.profileID).register(
            panel: panel,
            ownerID: ownerID,
            activePanelID: activePanelID,
            focusPanel: focusPanel
        )
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
