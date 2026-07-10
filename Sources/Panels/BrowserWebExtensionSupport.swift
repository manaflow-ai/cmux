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
    private struct TabMetadataSnapshot: Equatable {
        let title: String?
        let url: URL?
        let isLoading: Bool
        let isMuted: Bool

        @MainActor
        init(panel: BrowserPanel) {
            title = panel.webView.title
            url = panel.webView.url
            isLoading = panel.webView.isLoading
            isMuted = panel.isMuted
        }

        func changedProperties(
            comparedTo previous: TabMetadataSnapshot
        ) -> WKWebExtension.TabChangedProperties {
            var properties: WKWebExtension.TabChangedProperties = []
            if title != previous.title { properties.insert(.title) }
            if url != previous.url { properties.insert(.URL) }
            if isLoading != previous.isLoading { properties.insert(.loading) }
            if isMuted != previous.isMuted { properties.insert(.muted) }
            return properties
        }
    }

    /// Fixed identifier so extension storage (e.g. the Bitwarden vault cache)
    /// persists across app launches.
    private static let controllerIdentifier = UUID(uuidString: "8C0FDE2B-6EFD-4E8C-9E70-8E7D0A4C51B7")!

    @ObservationIgnored
    let controller: WKWebExtensionController
    @ObservationIgnored
    let permissionStateStore = BrowserWebExtensionPermissionStateStore()

    var actionSnapshotIDs: [String] = []
    var actionSnapshotRevision = 0
    var loadErrors: [String] = []

    @ObservationIgnored
    var settingsObservationTask: Task<Void, Never>?
    @ObservationIgnored
    var settingsLoadGeneration = 0
    @ObservationIgnored
    var settingsStore: JSONConfigStore?
    @ObservationIgnored
    var settingsKey: JSONKey<[BrowserWebExtensionEntry]>?
    @ObservationIgnored
    var browserAvailabilityObserverToken: NSObjectProtocol?
    @ObservationIgnored
    var windowFocusObserverToken: NSObjectProtocol?
    @ObservationIgnored
    var loadedByEntryID: [String: BrowserWebExtensionLoadedRecord] = [:]
    @ObservationIgnored
    var loadedEntryIDsInOrder: [String] = []
    @ObservationIgnored
    var loadErrorsByEntryID: [String: String] = [:]
    @ObservationIgnored
    var loadErrorUpdateContinuations: [UUID: AsyncStream<[String: String]>.Continuation] = [:]
    @ObservationIgnored
    var tabAdapters: [UUID: BrowserWebExtensionTabAdapter] = [:]
    @ObservationIgnored
    private var tabMetadataSnapshotsByPanelID: [UUID: TabMetadataSnapshot] = [:]
    @ObservationIgnored
    private var pendingTabMetadataPanelIDs: Set<UUID> = []
    @ObservationIgnored
    private var tabMetadataFlushTask: Task<Void, Never>?
    @ObservationIgnored
    var actionSnapshotInvalidationsByPanelID: [UUID: BrowserWebExtensionActionSnapshotInvalidation] = [:]
    @ObservationIgnored
    var permissionObserverTokensByEntryID: [String: [NSObjectProtocol]] = [:]
    @ObservationIgnored
    var orderedPanelIDs: [UUID] = []
    @ObservationIgnored
    private(set) var activePanelID: UUID?
    @ObservationIgnored
    private var activePanelIDsByWindow: [ObjectIdentifier: UUID] = [:]
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
        windowFocusObserverToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self, weak window] in
                guard let window else { return }
                self?.noteWindowBecameKey(window)
            }
        }
    }

    deinit {
        settingsObservationTask?.cancel()
        tabMetadataFlushTask?.cancel()
        if let browserAvailabilityObserverToken {
            NotificationCenter.default.removeObserver(browserAvailabilityObserverToken)
        }
        if let windowFocusObserverToken {
            NotificationCenter.default.removeObserver(windowFocusObserverToken)
        }
        // Permission-state observer tokens need no explicit removal here: the
        // block-based NotificationCenter tokens auto-unregister when they
        // deallocate, which happens as the dictionaries holding them release
        // with self. (Calling the @MainActor removal helper from nonisolated
        // deinit does not compile.)
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
        settingsStore = jsonStore
        settingsKey = catalog.browser.webExtensions
        guard browserAvailabilityObserverToken == nil else { return }
        let key = catalog.browser.webExtensions
        browserAvailabilityObserverToken = NotificationCenter.default.addObserver(
            forName: BrowserAvailabilitySettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self, jsonStore] _ in
            Task { @MainActor in
                self?.reconcileBrowserAvailability(jsonStore: jsonStore, key: key)
            }
        }
        reconcileBrowserAvailability(jsonStore: jsonStore, key: key)
    }

    private func reconcileBrowserAvailability(
        jsonStore: JSONConfigStore,
        key: JSONKey<[BrowserWebExtensionEntry]>
    ) {
        if BrowserAvailabilitySettings.isEnabled() {
            startSettingsObservation(jsonStore: jsonStore, key: key)
        } else {
            stopSettingsObservationAndUnload()
        }
    }

    private func startSettingsObservation(
        jsonStore: JSONConfigStore,
        key: JSONKey<[BrowserWebExtensionEntry]>
    ) {
        guard settingsObservationTask == nil else { return }
        settingsLoadGeneration &+= 1
        settingsObservationTask = Task { @MainActor [weak self] in
            for await entries in jsonStore.values(for: key) {
                guard let self else { return }
                await self.apply(entries: entries, generation: self.settingsLoadGeneration)
            }
        }
    }

    private func stopSettingsObservationAndUnload() {
        settingsLoadGeneration &+= 1
        settingsObservationTask?.cancel()
        settingsObservationTask = nil
        if !unloadAllWebExtensions() {
            BrowserAvailabilitySettings.setDisabled(false)
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
        tabMetadataSnapshotsByPanelID[panel.id] = TabMetadataSnapshot(panel: panel)
        actionSnapshotInvalidationsByPanelID[panel.id] = BrowserWebExtensionActionSnapshotInvalidation()
        orderedPanelIDs.append(panel.id)
        if activePanelID == nil { activePanelID = panel.id }
        rememberActivePanel(panel.id)
        controller.didOpenTab(adapter)
    }

    func unregister(panelID: UUID) {
        guard let adapter = tabAdapters.removeValue(forKey: panelID) else { return }
        tabMetadataSnapshotsByPanelID.removeValue(forKey: panelID)
        pendingTabMetadataPanelIDs.remove(panelID)
        orderedPanelIDs.removeAll { $0 == panelID }
        activePanelIDsByWindow = activePanelIDsByWindow.filter { $0.value != panelID }
        actionSnapshotInvalidationsByPanelID.removeValue(forKey: panelID)
        controller.didCloseTab(adapter, windowIsClosing: false)
        if activePanelID == panelID {
            activePanelID = orderedPanelIDs.last
            // Tell extensions which tab is active now, or they keep acting on
            // the closed one until the next focus change.
            if let successor = activePanelID.flatMap({ tabAdapters[$0] }) {
                controller.didActivateTab(successor, previousActiveTab: adapter)
                refreshActionSnapshots(for: successor.panel?.id)
            }
        }
    }

    func noteActivated(panelID: UUID) {
        guard tabAdapters[panelID] != nil else { return }
        rememberActivePanel(panelID)
        guard activePanelID != panelID else { return }
        let previousPanelID = activePanelID
        let previous = previousPanelID.flatMap { tabAdapters[$0] }
        activePanelID = panelID
        if let adapter = tabAdapters[panelID] {
            controller.didActivateTab(adapter, previousActiveTab: previous)
        }
        refreshActionSnapshots(for: previousPanelID)
        refreshActionSnapshots(for: panelID)
    }

    func noteWindowBecameKey(_ window: NSWindow) {
        let focusedWindow = webExtensionWindow(for: window)
        if (focusedWindow as AnyObject?) === windowAdapter,
           let panelID = activePanelID(in: window) {
            noteActivated(panelID: panelID)
        }
        controller.didFocusWindow(focusedWindow)
    }

    func webExtensionWindow(for window: NSWindow) -> (any WKWebExtensionWindow)? {
        if let popout = popouts.first(where: { $0.window === window }) {
            return popout
        }
        return activePanelID(in: window) == nil ? nil : windowAdapter
    }

    private func rememberActivePanel(_ panelID: UUID) {
        guard let window = tabAdapters[panelID]?.panel?.webView.window else { return }
        activePanelIDsByWindow[ObjectIdentifier(window)] = panelID
    }

    private func activePanelID(in window: NSWindow) -> UUID? {
        let windowID = ObjectIdentifier(window)
        if let rememberedPanelID = activePanelIDsByWindow[windowID],
           tabAdapters[rememberedPanelID]?.panel?.webView.window === window {
            return rememberedPanelID
        }
        guard let fallbackPanelID = orderedPanelIDs.reversed().first(where: {
            tabAdapters[$0]?.panel?.webView.window === window
        }) else {
            activePanelIDsByWindow.removeValue(forKey: windowID)
            return nil
        }
        activePanelIDsByWindow[windowID] = fallbackPanelID
        return fallbackPanelID
    }

    func noteTabMetadataChanged(panelID: UUID) {
        guard tabAdapters[panelID] != nil else { return }
        pendingTabMetadataPanelIDs.insert(panelID)
        guard tabMetadataFlushTask == nil else { return }
        tabMetadataFlushTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.tabMetadataFlushTask = nil
            self.flushPendingTabMetadataChanges()
        }
    }

    private func flushPendingTabMetadataChanges() {
        let panelIDs = pendingTabMetadataPanelIDs
        pendingTabMetadataPanelIDs.removeAll()
        for panelID in panelIDs {
            guard let adapter = tabAdapters[panelID], let panel = adapter.panel else {
                tabMetadataSnapshotsByPanelID.removeValue(forKey: panelID)
                continue
            }
            let current = TabMetadataSnapshot(panel: panel)
            guard let previous = tabMetadataSnapshotsByPanelID.updateValue(current, forKey: panelID) else {
                continue
            }
            let properties = current.changedProperties(comparedTo: previous)
            guard !properties.isEmpty else { continue }
            controller.didChangeTabProperties(properties, for: adapter)
            refreshActionSnapshots(for: panelID)
        }
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

/// Creates the app-wide web-extension host at launch on OS versions that
/// support `WKWebExtensionController`; returns nil elsewhere.
@MainActor
func makeBrowserWebExtensionHostAtLaunch(
    jsonStore: JSONConfigStore,
    catalog: SettingCatalog
) -> (any BrowserWebExtensionHosting)? {
    guard #available(macOS 15.4, *) else { return nil }
    let support = BrowserWebExtensionSupport()
    support.configure(jsonStore: jsonStore, catalog: catalog)
    StartupBreadcrumbLog.append("app.init.browserWebExtensions.configured")
    return support
}

extension BrowserPanel {
    func noteWebExtensionActivated() {
        browserWebExtensionHost?.noteActivated(panelID: id)
    }

    func performWebExtensionCommand(for event: NSEvent) -> Bool {
        guard let browserWebExtensionHost else { return false }
        noteWebExtensionActivated()
        return browserWebExtensionHost.performCommand(for: event)
    }

    func registerWebExtensionIfNeeded() {
        guard !isRegisteredForWebExtensions, let browserWebExtensionHost else { return }
        isRegisteredForWebExtensions = true
        browserWebExtensionHost.register(panel: self)
    }

    func unregisterWebExtensionIfNeeded() {
        guard isRegisteredForWebExtensions else { return }
        isRegisteredForWebExtensions = false
        browserWebExtensionHost?.unregister(panelID: id)
    }

    @available(macOS 15.4, *)
    var browserWebExtensionSupport: BrowserWebExtensionSupport? {
        browserWebExtensionHost as? BrowserWebExtensionSupport
    }
}
