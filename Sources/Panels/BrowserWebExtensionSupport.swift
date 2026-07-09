import AppKit
import CmuxSettings
import Observation
import SwiftUI
import WebKit

/// Hosts Chrome/Safari-style web extensions in the built-in browser via WebKit's
/// native `WKWebExtensionController` API (macOS 15.4+).
///
/// The app composition root owns one instance and injects it into browser panels.
/// Its persistent controller identifier keeps extension storage stable across app
/// launches. Extensions come from:
/// - the `browser.webExtensions` entries in cmux settings (managed in
///   Settings → Browser → Extensions), and
/// - directories listed in the `CMUX_BROWSER_EXTENSIONS` environment variable
///   (colon-separated paths to unpacked extensions or `.appex` bundles).
@available(macOS 15.4, *)
@MainActor
@Observable
final class BrowserWebExtensionSupport: NSObject, BrowserWebExtensionHosting {
    /// Fixed identifier so extension storage (e.g. the Bitwarden vault cache)
    /// persists across app launches.
    private static let controllerIdentifier = UUID(uuidString: "8C0FDE2B-6EFD-4E8C-9E70-8E7D0A4C51B7")!

    @ObservationIgnored
    let controller: WKWebExtensionController
    @ObservationIgnored
    let permissionStateStore = BrowserWebExtensionPermissionStateStore()

    var actionSnapshots: [BrowserWebExtensionActionSnapshot] = []
    var loadErrors: [String] = []

    @ObservationIgnored
    var settingsObservationTask: Task<Void, Never>?
    @ObservationIgnored
    var loadedByEntryID: [String: BrowserWebExtensionLoadedRecord] = [:]
    @ObservationIgnored
    var loadedEntryIDsInOrder: [String] = []
    @ObservationIgnored
    var loadErrorsByEntryID: [String: String] = [:]
    @ObservationIgnored
    var tabAdapters: [UUID: BrowserWebExtensionTabAdapter] = [:]
    @ObservationIgnored
    var permissionObserverTokensByEntryID: [String: [NSObjectProtocol]] = [:]
    @ObservationIgnored
    var orderedPanelIDs: [UUID] = []
    @ObservationIgnored
    private(set) var activePanelID: UUID?
    @ObservationIgnored
    private(set) lazy var windowAdapter = BrowserWebExtensionWindowAdapter(support: self)
    @ObservationIgnored
    var popouts: [BrowserWebExtensionPopoutWindowController] = []

    /// Anchor for the next action popup presentation, set by the toolbar button
    /// immediately before calling `performAction(context:panel:anchorView:)`.
    @ObservationIgnored
    weak var pendingPopupAnchorView: NSView?

    override init() {
        let configuration = WKWebExtensionController.Configuration(identifier: Self.controllerIdentifier)
        // Extension-owned web views (background page, action popup) get WebKit's
        // default user agent, which lacks the " Safari/" token. Extensions like
        // Bitwarden classify the browser from the UA and crash on an unknown one,
        // so present the same Safari application identity the browser panels use.
        let webViewConfiguration = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        webViewConfiguration.applicationNameForUserAgent = BrowserUserAgentSettings.safariApplicationNameForUserAgent
        configuration.webViewConfiguration = webViewConfiguration
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    deinit {
        settingsObservationTask?.cancel()
        removeAllPermissionStateObservers()
    }

    // MARK: - Configuration attachment

    /// Attaches the shared extension controller to a browser web view configuration.
    func attach(to configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
    }

    func webViewConfiguration(forNavigatingTo url: URL) -> BrowserWebExtensionNavigationConfiguration? {
        guard let context = controller.extensionContext(for: url),
              let webViewConfiguration = context.webViewConfiguration else {
            return nil
        }
        return BrowserWebExtensionNavigationConfiguration(
            contextIdentifier: ObjectIdentifier(context),
            webViewConfiguration: webViewConfiguration
        )
    }

    // MARK: - Settings-driven loading

    /// Starts observing `browser.webExtensions` and keeps loaded extensions in
    /// sync: newly enabled entries load, disabled/removed entries unload.
    /// Called once from app startup so extensions begin loading before the
    /// first browser page navigates.
    func configure(jsonStore: JSONConfigStore, catalog: SettingCatalog) {
        guard settingsObservationTask == nil else { return }
        let key = catalog.browser.webExtensions
        settingsObservationTask = Task { @MainActor [weak self] in
            for await entries in jsonStore.values(for: key) {
                guard let self else { return }
                await self.apply(entries: entries)
            }
        }
    }

    static func environmentExtensionPaths() -> [String] {
        guard let env = ProcessInfo.processInfo.environment["CMUX_BROWSER_EXTENSIONS"] else { return [] }
        return env.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Tab lifecycle (called from BrowserPanel)

    func register(panel: BrowserPanel) {
        guard tabAdapters[panel.id] == nil else { return }
        let adapter = BrowserWebExtensionTabAdapter(panel: panel, support: self)
        tabAdapters[panel.id] = adapter
        orderedPanelIDs.append(panel.id)
        if activePanelID == nil { activePanelID = panel.id }
        controller.didOpenTab(adapter)
    }

    func unregister(panelID: UUID) {
        guard let adapter = tabAdapters.removeValue(forKey: panelID) else { return }
        orderedPanelIDs.removeAll { $0 == panelID }
        controller.didCloseTab(adapter, windowIsClosing: false)
        if activePanelID == panelID {
            activePanelID = orderedPanelIDs.last
            // Tell extensions which tab is active now, or they keep acting on
            // the closed one until the next focus change.
            if let successor = activePanelID.flatMap({ tabAdapters[$0] }) {
                controller.didActivateTab(successor, previousActiveTab: adapter)
            }
        }
    }

    func noteActivated(panelID: UUID) {
        guard tabAdapters[panelID] != nil, activePanelID != panelID else { return }
        let previous = activePanelID.flatMap { tabAdapters[$0] }
        activePanelID = panelID
        if let adapter = tabAdapters[panelID] {
            controller.didActivateTab(adapter, previousActiveTab: previous)
        }
        rebuildActionSnapshots()
    }

    func noteTabMetadataChanged(panelID: UUID) {
        guard let adapter = tabAdapters[panelID] else { return }
        controller.didChangeTabProperties([.title, .URL, .loading, .muted], for: adapter)
    }

    func tabAdapter(for panelID: UUID) -> BrowserWebExtensionTabAdapter? {
        tabAdapters[panelID]
    }

    var orderedTabAdapters: [BrowserWebExtensionTabAdapter] {
        orderedPanelIDs.compactMap { tabAdapters[$0] }
    }

    var activeTabAdapter: BrowserWebExtensionTabAdapter? {
        activePanelID.flatMap { tabAdapters[$0] }
    }

    func indexInWindow(of panelID: UUID) -> Int {
        orderedPanelIDs.firstIndex(of: panelID) ?? 0
    }

    // MARK: - Action popup

    /// Performs the extension's toolbar action for `panel`, anchoring any popup
    /// the extension presents to `anchorView`.
    func performAction(context: WKWebExtensionContext, panel: BrowserPanel, anchorView: NSView?) {
        noteActivated(panelID: panel.id)
        pendingPopupAnchorView = anchorView
        context.performAction(for: tabAdapter(for: panel.id))
    }

    // MARK: - Keyboard commands

    /// Offers a key equivalent to loaded extensions' declared commands
    /// (e.g. Bitwarden's ⌘⇧L autofill). Returns true when one handled it.
    func performCommand(for event: NSEvent) -> Bool {
        for record in loadedRecordsInOrder where record.context.performCommand(for: event) {
#if DEBUG
            cmuxDebugLog("browser.webext.command handled name=\(record.context.webExtension.displayName ?? "?")")
#endif
            return true
        }
        return false
    }

    // MARK: - Popout windows

    func popoutDidClose(_ popout: BrowserWebExtensionPopoutWindowController) {
        guard popouts.contains(where: { $0 === popout }) else { return }
        popouts.removeAll { $0 === popout }
        controller.didCloseTab(popout.tab, windowIsClosing: true)
        controller.didCloseWindow(popout)
    }
}
