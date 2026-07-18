import AppKit
import Foundation
import WebKit

/// Loads Safari Web Extensions (WebExtension `manifest.json` bundles, the same
/// format Safari and Chrome use) into the cmux browser webviews registered for
/// one browser profile.
///
/// Each instance owns one controller, context set, tab registry, approval file,
/// and install directory. The built-in profile keeps the legacy
/// `~/.config/cmux/browser-extensions/` directory; other profiles use isolated
/// child directories. Each entry must contain a `manifest.json` at its root.
///
/// Installing an extension into the directory is treated as consent for required
/// manifest permissions and match patterns. Optional runtime requests are denied
/// without showing a disruptive modal prompt.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionsManager: NSObject {
    /// System WebKit advertises the `notifications` manifest permission but
    /// omits the JavaScript namespace outside its private test mode. Extensions
    /// such as 1Password register notification listeners during startup without
    /// feature detection, so the missing namespace aborts their background page.
    /// Keep an in-memory implementation until WebKit ships the public API.
    static let notificationsCompatibilityScriptSource = #"""
    (() => {
      const notifications = new Map();
      const makeEvent = () => {
        const listeners = new Set();
        return {
          addListener(listener) { if (typeof listener === 'function') listeners.add(listener); },
          removeListener(listener) { listeners.delete(listener); },
          hasListener(listener) { return listeners.has(listener); },
          hasListeners() { return listeners.size > 0; }
        };
      };
      const complete = (value, callback) => {
        if (typeof callback === 'function') queueMicrotask(() => callback(value));
        return Promise.resolve(value);
      };
      const api = {
        onClicked: makeEvent(),
        onButtonClicked: makeEvent(),
        onClosed: makeEvent(),
        create(identifier, options, callback) {
          if (typeof identifier !== 'string') {
            callback = options;
            options = identifier;
            identifier = crypto.randomUUID();
          }
          notifications.set(identifier, options || {});
          return complete(identifier, callback);
        },
        update(identifier, options, callback) {
          const exists = notifications.has(identifier);
          if (exists) notifications.set(identifier, { ...notifications.get(identifier), ...options });
          return complete(exists, callback);
        },
        clear(identifier, callback) {
          return complete(notifications.delete(identifier), callback);
        },
        getAll(callback) {
          return complete(Object.fromEntries(notifications), callback);
        },
        getPermissionLevel(callback) {
          return complete('granted', callback);
        }
      };
      const install = () => {
        for (const namespace of [globalThis.chrome, globalThis.browser]) {
          if (!namespace || namespace.notifications) continue;
          try {
            Object.defineProperty(namespace, 'notifications', {
              configurable: true,
              enumerable: true,
              value: api
            });
          } catch (_) {}
        }
      };
      install();
      queueMicrotask(install);
    })();
    """#

    typealias AppExtensionLoader = @MainActor (Bundle) async throws -> WKWebExtension

    private final class PendingActionInvocation {
        weak var anchorView: NSView?
        let panelID: UUID

        init(anchorView: NSView?, panelID: UUID) {
            self.anchorView = anchorView
            self.panelID = panelID
        }
    }

    private struct ActionInvocationKey: Hashable {
        let extensionIdentifier: String
        let panelID: UUID
    }

    private struct ActionUpdateKey: Hashable {
        let extensionIdentifier: String
        let panelID: UUID?
    }

    private final class WeakPopupWebView {
        weak var webView: WKWebView?

        init(_ webView: WKWebView) {
            self.webView = webView
        }
    }

    private enum LoadWaiter {
        case pendingRegistration
        case waiting(CheckedContinuation<Void, Never>)
    }

    /// Fixed controller identifier so extension storage (`browser.storage`,
    /// declarativeNetRequest state) persists across launches.
    private static let controllerIdentifier = UUID(uuidString: "3B7D2A9E-5C41-4F8A-B6D0-9E2C7A51F3D8")!

    let controller: WKWebExtensionController
    let directory: URL
    let profileID: UUID?
    var loadTask: Task<Void, Never>?
    private let directoryRepository = BrowserWebExtensionDirectoryRepository()
    private let catalogPackageRepository = BrowserWebExtensionCatalogPackageRepository()
    private let appExtensionLoader: AppExtensionLoader
    private(set) var isLoaded = false
    private var loadWaiters: [UUID: LoadWaiter] = [:]
    private(set) var loadedContexts: [WKWebExtensionContext] = []
    private(set) var loadErrors: [(url: URL, error: any Error)] = []
    private var toolbarPinnedExtensionIdentifiers = Set<String>()
    private var tabAdapters: [UUID: BrowserWebExtensionTabAdapter] = [:]
    private var windowAdapters: [UUID: BrowserWebExtensionWindowAdapter] = [:]
    private var pendingActionInvocations: [ActionInvocationKey: [PendingActionInvocation]] = [:]
    private var lastActionInvocations: [ActionInvocationKey: PendingActionInvocation] = [:]
    private var popupWebViews: [String: WeakPopupWebView] = [:]
    private var actionUpdateFlushTask: Task<Void, Never>?
    private var pendingActionUpdates: [ActionUpdateKey: PendingActionUpdate] = [:]
    private var installTasks: [UUID: Task<BrowserWebExtensionInstallReceipt, any Error>] = [:]
    private(set) var isShutDown = false

    private struct PendingActionUpdate {
        let action: WKWebExtension.Action?
        let context: WKWebExtensionContext
    }

    private struct PresentationIconCacheEntry {
        let image: NSImage
        let data: Data?
    }

    private static let actionUpdateMinimumInterval: Duration = .milliseconds(50)
    private var presentationIconCache: [ActionUpdateKey: PresentationIconCacheEntry] = [:]

    init(
        directory: URL,
        controllerIdentifier: UUID? = nil,
        controllerConfiguration: WKWebExtensionController.Configuration? = nil,
        websiteDataStore: WKWebsiteDataStore? = nil,
        profileID: UUID? = nil,
        appExtensionLoader: @escaping AppExtensionLoader = { bundle in
            try await WKWebExtension(appExtensionBundle: bundle)
        }
    ) {
        self.directory = directory
        self.profileID = profileID
        self.appExtensionLoader = appExtensionLoader
        let configuration = controllerConfiguration
            ?? WKWebExtensionController.Configuration(identifier: controllerIdentifier ?? Self.controllerIdentifier)
        if let websiteDataStore {
            configuration.defaultWebsiteDataStore = websiteDataStore
        }
        configuration.webViewConfiguration.applicationNameForUserAgent = "Version/18.4 Safari/605.1.15 cmux"
        configuration.webViewConfiguration.userContentController.addUserScript(
            WKUserScript(
                source: Self.notificationsCompatibilityScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
#if DEBUG
        configuration.webViewConfiguration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserPanel.telemetryHookBootstrapScriptSource
                    + "\n;\n"
                    + Self.extensionTelemetryBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
#endif
        self.controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        loadTask?.cancel()
        loadTask = nil
        for task in installTasks.values { task.cancel() }
        installTasks.removeAll()
        actionUpdateFlushTask?.cancel()
        actionUpdateFlushTask = nil
        pendingActionUpdates.removeAll()
        presentationIconCache.removeAll()
        pendingActionInvocations.removeAll()
        lastActionInvocations.removeAll()
        popupWebViews.removeAll()
        for context in loadedContexts {
            _ = try? controller.unload(context)
        }
        loadedContexts.removeAll()
        toolbarPinnedExtensionIdentifiers.removeAll()
        loadErrors.removeAll()
        tabAdapters.removeAll()
        windowAdapters.removeAll()
        resumeLoadWaiters()
    }

    func shutdownAndRemoveDirectory() async {
        shutdown()
        await directoryRepository.shutdownAndRemoveDirectory(directory)
    }

    /// Directories and `.zip` archives directly inside `directory`. Hidden
    /// entries are skipped so `.DS_Store` and dotfiles never surface as errors.
    nonisolated static func candidateURLs(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { url in
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    return true
                }
                return url.pathExtension.lowercased() == "zip"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func startLoading() {
        guard !isShutDown, loadTask == nil else { return }
        loadTask = Task { await loadExtensions() }
    }

    /// Suspends until the in-flight extension load finishes. Callers can cancel
    /// their own wait, but readiness never falls back to an elapsed-time guess:
    /// first navigation starts only after every approved context is registered.
    func waitUntilLoaded() async {
        startLoading()
        guard !isLoaded, loadTask != nil else { return }
        let waiterID = UUID()
        loadWaiters[waiterID] = .pendingRegistration
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard loadWaiters[waiterID] != nil else {
                    continuation.resume()
                    return
                }
                loadWaiters[waiterID] = .waiting(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeLoadWaiter(waiterID)
            }
        }
    }

    /// UI presentation waits for the same manager-owned readiness invariant as
    /// navigation and installation.
    func waitUntilPresentationReady() async {
        startLoading()
        await loadTask?.value
    }

    private func resumeLoadWaiter(_ id: UUID) {
        guard let waiter = loadWaiters.removeValue(forKey: id) else { return }
        if case let .waiting(continuation) = waiter {
            continuation.resume()
        }
    }

    private func resumeLoadWaiters() {
        let waiters = Array(loadWaiters.values)
        loadWaiters.removeAll()
        for waiter in waiters {
            if case let .waiting(continuation) = waiter {
                continuation.resume()
            }
        }
    }

    func loadExtensions() async {
        defer {
            if !isShutDown { isLoaded = true }
            resumeLoadWaiters()
        }
        guard !isShutDown else { return }
        toolbarPinnedExtensionIdentifiers = (try? await directoryRepository
            .toolbarPinnedExtensionIdentifiers(in: directory)) ?? []
        guard !Task.isCancelled, !isShutDown else { return }
        let discovery: BrowserWebExtensionApprovalDiscoveryResult
        do {
            discovery = try await directoryRepository.approvedCandidateURLs(in: directory)
        } catch {
            guard !isShutDown else { return }
            loadErrors.append((url: directory, error: error))
            return
        }
        loadErrors.append(contentsOf: discovery.failures.map { failure in
            (
                url: failure.url,
                error: BrowserWebExtensionApprovalValidationError(message: failure.message)
            )
        })
        guard !Task.isCancelled, !isShutDown else { return }
        for url in discovery.candidates {
            guard !Task.isCancelled, !isShutDown else { return }
            do {
                let context = try await loadExtension(at: url)
#if DEBUG
                cmuxDebugLog(
                    "browser.extensions.loaded name=\(context.webExtension.displayName ?? url.lastPathComponent) " +
                    "permissions=\(context.webExtension.requestedPermissions.count) " +
                    "patterns=\(context.webExtension.allRequestedMatchPatterns.count)"
                )
#endif
            } catch {
                guard !isShutDown, !Task.isCancelled else { return }
                loadErrors.append((url: url, error: error))
#if DEBUG
                cmuxDebugLog("browser.extensions.load-failed entry=\(url.lastPathComponent) error=\(error)")
#endif
            }
        }
        for reference in discovery.appExtensionReferences {
            guard !Task.isCancelled, !isShutDown else { return }
            do {
                let context = try await loadAppExtensionBundle(reference)
#if DEBUG
                cmuxDebugLog(
                    "browser.extensions.loaded-app-bundle name=\(context.webExtension.displayName ?? reference.installationName) " +
                    "bundle=\(reference.bundleIdentifier)"
                )
#endif
            } catch {
                guard !isShutDown, !Task.isCancelled else { return }
                loadErrors.append((url: reference.bundleURL, error: error))
#if DEBUG
                cmuxDebugLog(
                    "browser.extensions.load-app-bundle-failed bundle=\(reference.bundleIdentifier) error=\(error)"
                )
#endif
            }
        }
    }

    func installExtension(from source: URL) async throws -> BrowserWebExtensionInstallReceipt {
        try await runTrackedInstall { manager in
            try await manager.performInstallExtension(from: source)
        }
    }

    private func performInstallExtension(from source: URL) async throws -> BrowserWebExtensionInstallReceipt {
        try requireActive()
        // Serialize installs after startup discovery so the same package cannot
        // be loaded once by each path when a user installs during app launch.
        await waitUntilLoaded()
        try requireActive()
        let installSource = try await directoryRepository.resolveInstallSource(at: source)
        try requireActive()
        switch installSource {
        case .managedPackage(let packageURL, let installationName):
            try await directoryRepository.validatePackageSize(at: packageURL)
            try requireActive()
            // Validate before copying. WKWebExtension accepts either a directory or
            // ZIP archive and parses the manifest plus referenced resources.
            _ = try await WKWebExtension(resourceBaseURL: packageURL)
            try requireActive()
            let destination = try await directoryRepository.installCandidate(
                from: packageURL,
                into: directory,
                destinationName: installationName
            )
            do {
                try requireActive()
                // Approval computes the package digest and rejects symbolic links.
                // Finish it before WebKit can execute any extension resource.
                try await directoryRepository.approveCandidate(at: destination, in: directory)
                try requireActive()
                let context = try await loadExtension(at: destination)
                return BrowserWebExtensionInstallReceipt(
                    name: context.webExtension.displayName
                        ?? destination.deletingPathExtension().lastPathComponent
                )
            } catch {
                await directoryRepository.removeInstalledCandidate(at: destination, from: directory)
                throw error
            }
        case .appExtensionBundle(let reference):
            // Keep the signed app-extension bundle attached. WebKit uses it to
            // forward browser.runtime native messages to the containing app.
            let webExtension = try await webExtension(for: reference)
            try requireActive()
            try await directoryRepository.approveAppExtensionReference(reference, in: directory)
            do {
                let context = try loadExtension(
                    webExtension,
                    installationName: reference.installationName,
                    supportsNativeMessaging: true
                )
                return BrowserWebExtensionInstallReceipt(
                    name: context.webExtension.displayName ?? reference.installationName
                )
            } catch {
                await directoryRepository.removeAppExtensionReference(reference, from: directory)
                throw error
            }
        }
    }

    func approveInstalledCandidate(_ candidate: URL) async throws {
        try requireActive()
        try await directoryRepository.approveCandidate(at: candidate, in: directory)
        try requireActive()
    }

    func installCatalogExtension(_ entry: BrowserWebExtensionCatalogEntry) async throws -> BrowserWebExtensionInstallReceipt {
        try await runTrackedInstall { manager in
            try manager.requireActive()
            let packageURL = try await manager.catalogPackageRepository.download(entry)
            defer {
                Task { await manager.catalogPackageRepository.removeDownloadedPackage(at: packageURL) }
            }
            try manager.requireActive()
            return try await manager.performInstallExtension(from: packageURL)
        }
    }

    func setToolbarActionPinned(
        _ isPinned: Bool,
        uniqueIdentifier: String
    ) async throws {
        try requireActive()
        guard let context = loadedContexts.first(where: {
            $0.uniqueIdentifier == uniqueIdentifier
        }), Self.definesAction(context.webExtension) else {
            throw BrowserWebExtensionToolbarPinError.actionUnavailable
        }
        let identifiers = try await directoryRepository.setToolbarActionPinned(
            isPinned,
            uniqueIdentifier: uniqueIdentifier,
            in: directory
        )
        try requireActive()
        toolbarPinnedExtensionIdentifiers = identifiers
        NotificationCenter.default.post(
            name: .browserWebExtensionActionDidChange,
            object: context.uniqueIdentifier,
            userInfo: [BrowserWebExtensionsPresentationSnapshot.NotificationKey.profileID: profileID ?? NSNull()]
        )
    }

    private func runTrackedInstall(
        _ operation: @escaping @MainActor (BrowserWebExtensionsManager) async throws -> BrowserWebExtensionInstallReceipt
    ) async throws -> BrowserWebExtensionInstallReceipt {
        try requireActive()
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await operation(self)
        }
        installTasks[operationID] = task
        defer { installTasks.removeValue(forKey: operationID) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func requireActive() throws {
        guard !isShutDown, !Task.isCancelled else { throw CancellationError() }
    }

    func register(
        panel: BrowserPanel,
        ownerID: UUID,
        activePanelID: @escaping @MainActor () -> UUID?,
        focusPriority: @escaping @MainActor () -> Int = { 0 },
        focusPanel: @escaping @MainActor (UUID) -> Void,
        orderedPanelIDs: @escaping @MainActor () -> [UUID] = { [] },
        createTab: @escaping @MainActor (Int, Bool, Bool) -> BrowserPanel? = { _, _, _ in nil }
    ) {
        if tabAdapters[panel.id] != nil { return }

        let windowAdapter: BrowserWebExtensionWindowAdapter
        if let existing = windowAdapters[ownerID] {
            windowAdapter = existing
        } else {
            windowAdapter = BrowserWebExtensionWindowAdapter(
                ownerID: ownerID,
                activePanelID: activePanelID,
                focusPriority: focusPriority,
                focusPanel: focusPanel,
                orderedPanelIDs: orderedPanelIDs,
                createTab: createTab
            )
            windowAdapters[ownerID] = windowAdapter
            controller.didOpenWindow(windowAdapter)
        }

        let tabAdapter = BrowserWebExtensionTabAdapter(panel: panel, windowAdapter: windowAdapter)
        tabAdapters[panel.id] = tabAdapter
        windowAdapter.tabAdapters.append(tabAdapter)
        if panel.internalPage == nil {
            controller.didOpenTab(tabAdapter)
        }
        windowAdapter.lastReportedVisiblePanelIDs = windowAdapter.compactTabs().compactMap { $0.panel?.id }
    }

    func unregister(panelID: UUID) {
        pendingActionInvocations = pendingActionInvocations.filter { $0.key.panelID != panelID }
        lastActionInvocations = lastActionInvocations.filter { $0.key.panelID != panelID }
        pendingActionUpdates = pendingActionUpdates.filter { $0.key.panelID != panelID }
        presentationIconCache = presentationIconCache.filter { $0.key.panelID != panelID }
        guard let tabAdapter = tabAdapters.removeValue(forKey: panelID) else { return }
        guard let windowAdapter = tabAdapter.windowAdapter else { return }
        if windowAdapter.lastReportedVisiblePanelIDs.contains(panelID) {
            controller.didCloseTab(tabAdapter, windowIsClosing: false)
        }
        windowAdapter.tabAdapters.removeAll { $0 === tabAdapter || $0.panel == nil }
        windowAdapter.lastReportedVisiblePanelIDs = windowAdapter.compactTabs().compactMap { $0.panel?.id }
        if windowAdapter.tabAdapters.isEmpty {
            windowAdapters.removeValue(forKey: windowAdapter.ownerID)
            controller.didCloseWindow(windowAdapter)
        }
    }

    func registrationOwner(
        for panelID: UUID
    ) -> (
        id: UUID,
        activePanelID: @MainActor () -> UUID?,
        focusPriority: @MainActor () -> Int,
        focusPanel: @MainActor (UUID) -> Void,
        orderedPanelIDs: @MainActor () -> [UUID],
        createTab: @MainActor (Int, Bool, Bool) -> BrowserPanel?
    )? {
        guard let windowAdapter = tabAdapters[panelID]?.windowAdapter else { return nil }
        return (
            windowAdapter.ownerID,
            windowAdapter.activePanelID,
            windowAdapter.focusPriority,
            windowAdapter.focusPanel,
            windowAdapter.orderedPanelIDs,
            windowAdapter.createTab
        )
    }

    func tabVisibilityDidChange(panelID: UUID) {
        guard let tabAdapter = tabAdapters[panelID],
              let windowAdapter = tabAdapter.windowAdapter else { return }
        let wasVisible = windowAdapter.lastReportedVisiblePanelIDs.contains(panelID)
        let isVisible = tabAdapter.panel?.internalPage == nil
        guard wasVisible != isVisible else { return }

        if isVisible {
            controller.didOpenTab(tabAdapter)
        } else {
            controller.didDeselectTabs([tabAdapter])
            controller.didCloseTab(tabAdapter, windowIsClosing: false)
        }
        windowAdapter.lastReportedVisiblePanelIDs = windowAdapter.compactTabs().compactMap { $0.panel?.id }
    }

    func synchronizeTabOrder(ownerID: UUID) {
        guard let windowAdapter = windowAdapters[ownerID] else { return }
        let previous = windowAdapter.lastReportedVisiblePanelIDs
        let currentAdapters = windowAdapter.compactTabs()
        let current = currentAdapters.compactMap { $0.panel?.id }
        defer { windowAdapter.lastReportedVisiblePanelIDs = current }
        guard previous != current,
              previous.count == current.count,
              Set(previous) == Set(current) else {
            return
        }

        let previousIndices = Dictionary(
            uniqueKeysWithValues: previous.enumerated().map { ($0.element, $0.offset) }
        )
        let currentIndices = Dictionary(
            uniqueKeysWithValues: current.enumerated().map { ($0.element, $0.offset) }
        )
        if let panelID = current.first(where: {
            previousIndices[$0] != currentIndices[$0]
        }),
           let oldIndex = previousIndices[panelID],
           let adapter = tabAdapters[panelID] {
            controller.didMoveTab(adapter, from: oldIndex, in: windowAdapter)
        }
    }

    func tabPropertiesDidChange(
        panelID: UUID,
        properties: WKWebExtension.TabChangedProperties
    ) {
        guard let tabAdapter = tabAdapters[panelID],
              tabAdapter.panel?.internalPage == nil else { return }
        controller.didChangeTabProperties(properties, for: tabAdapter)
    }

    func activateTab(panelID: UUID, previousPanelID: UUID?) {
        guard let tabAdapter = tabAdapters[panelID],
              tabAdapter.panel?.internalPage == nil else { return }
        let previousAdapter = previousPanelID
            .flatMap { tabAdapters[$0] }
            .flatMap { $0.panel?.internalPage == nil ? $0 : nil }
        if let previousAdapter, previousAdapter !== tabAdapter {
            controller.didDeselectTabs([previousAdapter])
        }
        controller.didSelectTabs([tabAdapter])
        controller.didActivateTab(tabAdapter, previousActiveTab: previousAdapter)
        controller.didFocusWindow(tabAdapter.windowAdapter)
    }

    func deactivateTab(panelID: UUID) {
        guard let tabAdapter = tabAdapters[panelID],
              tabAdapter.panel?.internalPage == nil else { return }
        controller.didDeselectTabs([tabAdapter])
    }

    func windowFocusDidChange() {
        controller.didFocusWindow(focusedWindowAdapter())
    }

    @discardableResult
    func performAction(
        uniqueIdentifier: String,
        in panel: BrowserPanel,
        anchorView: NSView?
    ) -> Bool {
        guard let context = loadedContexts.first(where: { $0.uniqueIdentifier == uniqueIdentifier }),
              let tabAdapter = tabAdapters[panel.id],
              let action = context.action(for: tabAdapter),
              action.isEnabled else {
            return false
        }
        let key = ActionInvocationKey(
            extensionIdentifier: context.uniqueIdentifier,
            panelID: panel.id
        )
        let invocation = PendingActionInvocation(
            anchorView: anchorView,
            panelID: panel.id
        )
        lastActionInvocations[key] = invocation
        if action.presentsPopup {
            pendingActionInvocations[key, default: []].append(invocation)
            // WebKit's delegate callback is delayed until the popup finishes
            // loading. Present its public popover immediately for a user click
            // after invoking the action so a slow extension still has a visible
            // loading surface while WebKit activates its background content.
            context.performAction(for: tabAdapter)
            do {
                try showPopup(action, for: context)
                return true
            } catch {
                pendingActionInvocations.removeValue(forKey: key)
                return false
            }
        }
        pendingActionInvocations.removeValue(forKey: key)
        // WebKit owns background activation for action events.
        // Waiting on loadBackgroundContent here can permanently swallow an
        // action when a service worker keeps that callback pending.
        context.performAction(for: tabAdapter)
        return true
    }

    private func loadExtension(at url: URL) async throws -> WKWebExtensionContext {
        try requireActive()
        let webExtension = try await WKWebExtension(resourceBaseURL: url)
        try requireActive()
        return try loadExtension(
            webExtension,
            installationName: url.lastPathComponent,
            supportsNativeMessaging: false
        )
    }

    private func loadAppExtensionBundle(
        _ reference: BrowserWebExtensionAppExtensionReference
    ) async throws -> WKWebExtensionContext {
        let webExtension = try await webExtension(for: reference)
        try requireActive()
        return try loadExtension(
            webExtension,
            installationName: reference.installationName,
            supportsNativeMessaging: true
        )
    }

    private func webExtension(
        for reference: BrowserWebExtensionAppExtensionReference
    ) async throws -> WKWebExtension {
        guard let bundle = Bundle(url: reference.bundleURL),
              bundle.bundleIdentifier == reference.bundleIdentifier else {
            throw BrowserWebExtensionInstallError.invalidPackage(
                reference.bundleURL.lastPathComponent
            )
        }
        return try await appExtensionLoader(bundle)
    }

    private func loadExtension(
        _ webExtension: WKWebExtension,
        installationName: String,
        supportsNativeMessaging: Bool
    ) throws -> WKWebExtensionContext {
        try requireActive()
        let context = WKWebExtensionContext(for: webExtension)
        // Stable identifier derived from the managed entry or app-extension
        // bundle identifier so storage survives extension and app updates.
        context.uniqueIdentifier = "cmux-browser-extension-\(installationName)"
        if !supportsNativeMessaging {
            // WKWebExtension's native messaging transport targets an embedded
            // Safari App Extension, not Chromium's executable-host protocol.
            // Mark it unavailable so portable extensions can feature-detect
            // and use their standalone path instead of waiting forever.
            context.unsupportedAPIs = [
                "browser.runtime.sendNativeMessage",
                "browser.runtime.connectNative",
            ]
        }
#if DEBUG
        context.isInspectable = true
        context.inspectionName = context.webExtension.displayName ?? installationName
#endif
        grantRequestedPermissions(in: context, for: webExtension)
        try controller.load(context)
        loadedContexts.append(context)
        enqueueActionUpdate(action: nil, context: context, panelID: nil)
        return context
    }

    func presentationSnapshot(for panelID: UUID? = nil) -> BrowserWebExtensionsPresentationSnapshot {
        let tabAdapter = panelID.flatMap { tabAdapters[$0] }
        return BrowserWebExtensionsPresentationSnapshot(
            state: isLoaded ? .ready : .loading,
            extensions: loadedContexts.map { context in
                let action = tabAdapter.flatMap { context.action(for: $0) }
                return presentationItem(for: context, action: action, panelID: panelID)
            },
            failures: loadErrors.map { failure in
                BrowserWebExtensionsPresentationSnapshot.Failure(
                    id: failure.url.path,
                    entryName: failure.url.lastPathComponent,
                    message: String(
                        localized: "browser.extensions.load.failed",
                        defaultValue: "The extension could not be loaded."
                    )
                )
            },
            directoryPath: directory.path
        )
    }

    func diagnosticPayload(matching identifier: String? = nil) -> [String: Any] {
        compactPopupWebViews()
        return [
            "extensions": matchingContexts(identifier).map { context in
                let identifier = context.uniqueIdentifier
                return [
                    "id": identifier,
                    "name": context.webExtension.displayName ?? identifier,
                    "version": context.webExtension.version ?? "",
                    "errors": context.errors.map(Self.errorPayload),
                    // WebKit owns background activation and reports lifecycle
                    // failures through the extension context's error collection.
                    "background_error": NSNull(),
                    "has_popup_webview": popupWebViews[identifier]?.webView != nil,
                    "inspectable": context.isInspectable,
                ] as [String: Any]
            },
            "load_errors": loadErrors.map { failure in
                [
                    "entry": failure.url.lastPathComponent,
                    "error": Self.errorPayload(failure.error),
                ]
            },
            "tabs": tabAdapters.values.compactMap { adapter -> [String: Any]? in
                guard let panel = adapter.panel else { return nil }
                return [
                    "panel_id": panel.id.uuidString,
                    "profile_id": panel.profileID.uuidString,
                    "has_expected_controller": panel.webView.configuration.webExtensionController === controller,
                ]
            },
        ]
    }

    func webViewPayload(matching identifier: String? = nil) -> [String: Any] {
        compactPopupWebViews()
        return [
            "webviews": matchingContexts(identifier).compactMap { context -> [String: Any]? in
                guard let webView = popupWebViews[context.uniqueIdentifier]?.webView else { return nil }
                return [
                    "id": popupWebViewIdentifier(for: context),
                    "extension_id": context.uniqueIdentifier,
                    "extension_name": context.webExtension.displayName ?? context.uniqueIdentifier,
                    "kind": "popup",
                    "url": webView.url?.absoluteString ?? "",
                    "title": webView.title ?? "",
                    "loading": webView.isLoading,
                ]
            }
        ]
    }

    func performAction(matching identifier: String, panelID: UUID) throws -> [String: Any] {
        guard let context = matchingContexts(identifier).first else {
            throw BrowserWebExtensionDiagnosticsError.extensionNotFound(identifier)
        }
        guard let panel = tabAdapters[panelID]?.panel else {
            throw BrowserWebExtensionDiagnosticsError.tabUnavailable
        }
        guard performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: nil
        ) else {
            throw BrowserWebExtensionActionError.unavailable
        }
        return [
            "performed": true,
            "extension_id": context.uniqueIdentifier,
            "extension_name": context.webExtension.displayName ?? context.uniqueIdentifier,
            "panel_id": panelID.uuidString,
        ]
    }

    func evaluateJavaScript(
        _ script: String,
        matching identifier: String,
        webViewIdentifier: String? = nil
    ) async throws -> [String: Any] {
#if !DEBUG
        throw BrowserWebExtensionDiagnosticsError.debugBuildRequired
#else
        compactPopupWebViews()
        guard let context = matchingContexts(identifier).first else {
            throw BrowserWebExtensionDiagnosticsError.extensionNotFound(identifier)
        }
        let expectedWebViewIdentifier = popupWebViewIdentifier(for: context)
        if let webViewIdentifier, webViewIdentifier != expectedWebViewIdentifier {
            throw BrowserWebExtensionDiagnosticsError.webViewNotFound(webViewIdentifier)
        }
        guard let webView = popupWebViews[context.uniqueIdentifier]?.webView else {
            throw BrowserWebExtensionDiagnosticsError.popupNotOpen(
                context.webExtension.displayName ?? context.uniqueIdentifier
            )
        }
        let value = try await webView.evaluateJavaScript(script)
        return [
            "extension_id": context.uniqueIdentifier,
            "webview_id": expectedWebViewIdentifier,
            "value": Self.jsonSafeValue(value),
        ]
#endif
    }

    func consolePayload(matching identifier: String) async throws -> [String: Any] {
        try await evaluateJavaScript(
            """
            (() => ({
              console: Array.isArray(window.__cmuxExtensionConsoleLog)
                ? window.__cmuxExtensionConsoleLog.slice()
                : (Array.isArray(window.__cmuxConsoleLog) ? window.__cmuxConsoleLog.slice() : []),
              errors: Array.isArray(window.__cmuxExtensionErrorLog)
                ? window.__cmuxExtensionErrorLog.slice()
                : (Array.isArray(window.__cmuxErrorLog) ? window.__cmuxErrorLog.slice() : [])
            }))()
            """,
            matching: identifier
        )
    }

    private func matchingContexts(_ identifier: String?) -> [WKWebExtensionContext] {
        guard let identifier, !identifier.isEmpty else { return loadedContexts }
        let folded = identifier.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return loadedContexts.filter { context in
            if context.uniqueIdentifier == identifier { return true }
            let name = context.webExtension.displayName ?? ""
            return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == folded
        }
    }

    func pageConfiguration(
        for url: URL
    ) -> (baseURL: URL, configuration: WKWebViewConfiguration)? {
        guard let context = loadedContexts.first(where: {
            Self.sameOrigin(url, $0.baseURL)
        }), let configuration = context.webViewConfiguration else {
            return nil
        }
        return (context.baseURL, configuration)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.caseInsensitiveCompare(rhs.scheme ?? "") == .orderedSame
            && lhs.host?.caseInsensitiveCompare(rhs.host ?? "") == .orderedSame
            && lhs.port == rhs.port
    }

    private func popupWebViewIdentifier(for context: WKWebExtensionContext) -> String {
        "popup:\(context.uniqueIdentifier)"
    }

    private func compactPopupWebViews() {
        popupWebViews = popupWebViews.filter { $0.value.webView != nil }
    }

    private static func jsonSafeValue(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if JSONSerialization.isValidJSONObject([value]) { return value }
        return String(describing: value)
    }

    private static func errorPayload(_ error: any Error) -> [String: Any] {
        let nsError = error as NSError
        return [
            "domain": nsError.domain,
            "code": nsError.code,
            "message": nsError.localizedDescription,
        ]
    }

#if DEBUG
    private static let extensionTelemetryBootstrapScriptSource = """
    (() => {
      if (window.__cmuxExtensionConsoleInstalled) return;
      window.__cmuxExtensionConsoleInstalled = true;
      window.__cmuxExtensionConsoleLog = [];
      window.__cmuxExtensionErrorLog = [];
      const describe = (value) => {
        if (value instanceof Error) {
          return { name: value.name, message: value.message, stack: value.stack || "" };
        }
        if (value && typeof value === 'object') {
          try { return JSON.parse(JSON.stringify(value)); }
          catch (_) {
            try { return Object.fromEntries(Object.getOwnPropertyNames(value).map(k => [k, String(value[k])])); }
            catch (_) { return String(value); }
          }
        }
        return value;
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const previous = console[level];
        console[level] = function(...args) {
          window.__cmuxExtensionConsoleLog.push({
            level,
            arguments: args.map(describe),
            timestamp_ms: Date.now()
          });
          if (window.__cmuxExtensionConsoleLog.length > 512) {
            window.__cmuxExtensionConsoleLog.splice(0, window.__cmuxExtensionConsoleLog.length - 512);
          }
          return previous.apply(this, args);
        };
      }
      window.addEventListener('error', event => {
        window.__cmuxExtensionErrorLog.push({
          message: event.message || '',
          source: event.filename || '',
          line: event.lineno || 0,
          column: event.colno || 0,
          error: describe(event.error),
          timestamp_ms: Date.now()
        });
      });
      window.addEventListener('unhandledrejection', event => {
        window.__cmuxExtensionErrorLog.push({
          message: 'Unhandled promise rejection',
          reason: describe(event.reason),
          timestamp_ms: Date.now()
        });
      });
    })();
    """
#endif

    private func grantRequestedPermissions(in context: WKWebExtensionContext, for webExtension: WKWebExtension) {
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    private static func definesAction(_ webExtension: WKWebExtension) -> Bool {
        webExtension.manifest["action"] != nil
            || webExtension.manifest["browser_action"] != nil
            || webExtension.manifest["page_action"] != nil
    }

    private func presentationItem(
        for context: WKWebExtensionContext,
        action: WKWebExtension.Action?,
        panelID: UUID?
    ) -> BrowserWebExtensionsPresentationSnapshot.Item {
        let key = ActionUpdateKey(
            extensionIdentifier: context.uniqueIdentifier,
            panelID: panelID
        )
        return BrowserWebExtensionsPresentationSnapshot.Item(
            id: context.uniqueIdentifier,
            name: context.webExtension.displayName ?? context.uniqueIdentifier,
            hasAction: Self.definesAction(context.webExtension),
            isToolbarPinned: toolbarPinnedExtensionIdentifiers.contains(context.uniqueIdentifier),
            isActionEnabled: action?.isEnabled ?? Self.definesAction(context.webExtension),
            badgeText: action?.badgeText ?? "",
            iconData: presentationIconData(
                for: action,
                webExtension: context.webExtension,
                cacheKey: key
            )
        )
    }

    private func enqueueActionUpdate(
        action: WKWebExtension.Action?,
        context: WKWebExtensionContext,
        panelID: UUID?
    ) {
        let key = ActionUpdateKey(
            extensionIdentifier: context.uniqueIdentifier,
            panelID: panelID
        )
        pendingActionUpdates[key] = PendingActionUpdate(action: action, context: context)
        guard actionUpdateFlushTask == nil else { return }
        actionUpdateFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.actionUpdateMinimumInterval)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.actionUpdateFlushTask = nil
            let updates = self.pendingActionUpdates
            self.pendingActionUpdates.removeAll()
            for (key, update) in updates {
                let item = self.presentationItem(
                    for: update.context,
                    action: update.action,
                    panelID: key.panelID
                )
                NotificationCenter.default.post(
                    name: .browserWebExtensionActionDidChange,
                    object: key.extensionIdentifier,
                    userInfo: [
                        BrowserWebExtensionsPresentationSnapshot.NotificationKey.panelID: key.panelID ?? NSNull(),
                        BrowserWebExtensionsPresentationSnapshot.NotificationKey.profileID: self.profileID ?? NSNull(),
                        BrowserWebExtensionsPresentationSnapshot.NotificationKey.item: item,
                    ]
                )
            }
        }
    }

    private func presentationIconData(
        for action: WKWebExtension.Action?,
        webExtension: WKWebExtension,
        cacheKey: ActionUpdateKey
    ) -> Data? {
        let size = CGSize(width: 32, height: 32)
        guard let image = action?.icon(for: size)
                ?? webExtension.actionIcon(for: size)
                ?? webExtension.icon(for: size) else {
            presentationIconCache.removeValue(forKey: cacheKey)
            return nil
        }
        if let cached = presentationIconCache[cacheKey], cached.image === image {
            return cached.data
        }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            presentationIconCache[cacheKey] = PresentationIconCacheEntry(image: image, data: nil)
            return nil
        }
        let data = bitmap.representation(using: .png, properties: [:])
        presentationIconCache[cacheKey] = PresentationIconCacheEntry(image: image, data: data)
        return data
    }
}

@available(macOS 15.4, *)
extension BrowserWebExtensionsManager: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        orderedWindowAdapters().map { $0 as any WKWebExtensionWindow }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedWindowAdapter()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let windowAdapter = (configuration.window as? BrowserWebExtensionWindowAdapter)
            ?? focusedWindowAdapter()
            ?? orderedWindowAdapters().first
        guard let windowAdapter,
              let panel = windowAdapter.createTab(
                configuration.index,
                configuration.shouldBeActive,
                configuration.shouldAddToSelection
              ),
              let tabAdapter = tabAdapters[panel.id] else {
            completionHandler(nil, BrowserWebExtensionNewTabError.creationFailed)
            return
        }
        if let url = configuration.url {
            panel.navigate(to: url)
        }
        completionHandler(tabAdapter, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        do {
            try showPopup(action, for: extensionContext)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    private func showPopup(
        _ action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext
    ) throws {
        guard let popover = action.popupPopover else {
            throw BrowserWebExtensionActionError.missingPopupAnchor
        }
        if !popover.isShown {
            guard let anchor = popupAnchor(for: action, extensionContext: extensionContext) else {
                throw BrowserWebExtensionActionError.missingPopupAnchor
            }
            popover.behavior = .transient
            popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
        }
        if let webView = action.popupWebView {
            popupWebViews[extensionContext.uniqueIdentifier] = WeakPopupWebView(webView)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        let panelID = (action.associatedTab as? BrowserWebExtensionTabAdapter)?.panel?.id
        enqueueActionUpdate(action: action, context: context, panelID: panelID)
    }

    private func popupAnchor(
        for action: WKWebExtension.Action,
        extensionContext: WKWebExtensionContext
    ) -> (view: NSView, rect: NSRect)? {
        let associatedPanel = (action.associatedTab as? BrowserWebExtensionTabAdapter)?.panel
        let key = associatedPanel.map {
            ActionInvocationKey(extensionIdentifier: extensionContext.uniqueIdentifier, panelID: $0.id)
        }

        if let key,
           var queue = pendingActionInvocations[key],
           !queue.isEmpty {
            let invocation = queue.removeFirst()
            if queue.isEmpty {
                pendingActionInvocations.removeValue(forKey: key)
            } else {
                pendingActionInvocations[key] = queue
            }
            if let anchor = invocation.anchorView, anchor.window != nil {
                return (anchor, anchor.bounds)
            }
        }

        if let key,
           let anchor = lastActionInvocations[key]?.anchorView,
           anchor.window != nil {
            return (anchor, anchor.bounds)
        }

        guard let webView = associatedPanel?.webView, webView.window != nil else { return nil }
        let point = NSPoint(x: webView.bounds.maxX - 1, y: webView.bounds.maxY - 1)
        return (webView, NSRect(origin: point, size: NSSize(width: 1, height: 1)))
    }

    // Required manifest permissions were granted at explicit installation.
    // Every runtime request is optional or redundant, so deny it without
    // presenting a sheet. A future inline permission surface can selectively
    // grant additional access without interrupting the user.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler([], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler([], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler([], nil)
    }

    private func orderedWindowAdapters() -> [BrowserWebExtensionWindowAdapter] {
        let live = windowAdapters.values.filter { !$0.compactTabs().isEmpty }
        return live.sorted { lhs, rhs in
            let lhsPriority = lhs.focusPriority()
            let rhsPriority = rhs.focusPriority()
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            return lhs.ownerID.uuidString < rhs.ownerID.uuidString
        }
    }

    private func focusedWindowAdapter() -> BrowserWebExtensionWindowAdapter? {
        guard NSApp.isActive else { return nil }
        return orderedWindowAdapters().first { $0.focusPriority() > 0 }
    }

#if DEBUG
    var debugPreferredFocusedWindowOwnerID: UUID? {
        orderedWindowAdapters().first { $0.focusPriority() > 0 }?.ownerID
    }
#endif
}

extension Notification.Name {
    static let browserWebExtensionActionDidChange = Notification.Name(
        "cmux.browserWebExtensionActionDidChange"
    )
}

private struct BrowserWebExtensionApprovalValidationError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@available(macOS 15.4, *)
private enum BrowserWebExtensionActionError: LocalizedError {
    case missingPopupAnchor
    case unavailable

    var errorDescription: String? {
        String(
            localized: "browser.extensions.action.unavailable",
            defaultValue: "The extension action could not be shown."
        )
    }
}

@available(macOS 15.4, *)
private enum BrowserWebExtensionNewTabError: LocalizedError {
    case creationFailed

    var errorDescription: String? {
        String(
            localized: "browser.extensions.error.openTabFailed",
            defaultValue: "The extension could not open a browser tab."
        )
    }
}

@available(macOS 15.4, *)
private enum BrowserWebExtensionToolbarPinError: LocalizedError {
    case actionUnavailable

    var errorDescription: String? {
        String(
            localized: "browser.extensions.action.unavailable",
            defaultValue: "The extension action could not be shown."
        )
    }
}

@available(macOS 15.4, *)
private enum BrowserWebExtensionDiagnosticsError: LocalizedError {
    case extensionNotFound(String)
    case tabUnavailable
    case webViewNotFound(String)
    case popupNotOpen(String)
    case debugBuildRequired

    var errorDescription: String? {
        switch self {
        case .extensionNotFound(let identifier):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.extensions.diagnostics.extensionNotFound",
                    defaultValue: "Extension not found: %@"
                ),
                identifier
            )
        case .tabUnavailable:
            return String(
                localized: "browser.extensions.error.tabUnavailable",
                defaultValue: "The browser tab is no longer available."
            )
        case .webViewNotFound(let identifier):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.extensions.diagnostics.webViewNotFound",
                    defaultValue: "Extension webview not found: %@"
                ),
                identifier
            )
        case .popupNotOpen(let name):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.extensions.diagnostics.popupNotOpen",
                    defaultValue: "Open the %@ extension popup before accessing its webview."
                ),
                name
            )
        case .debugBuildRequired:
            return String(
                localized: "browser.extensions.diagnostics.debugBuildRequired",
                defaultValue: "Extension JavaScript inspection is available only in cmux development builds."
            )
        }
    }
}
