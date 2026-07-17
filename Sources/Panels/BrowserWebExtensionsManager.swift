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
    private(set) var isLoaded = false
    private var loadWaiters: [UUID: LoadWaiter] = [:]
    private(set) var loadedContexts: [WKWebExtensionContext] = []
    private(set) var loadErrors: [(url: URL, error: any Error)] = []
    private var tabAdapters: [UUID: BrowserWebExtensionTabAdapter] = [:]
    private var windowAdapters: [UUID: BrowserWebExtensionWindowAdapter] = [:]
    private var pendingActionInvocations: [ActionInvocationKey: [PendingActionInvocation]] = [:]
    private var lastActionInvocations: [ActionInvocationKey: PendingActionInvocation] = [:]
    private var popupWebViews: [String: WeakPopupWebView] = [:]
    private var backgroundLoadErrors: [String: any Error] = [:]
    private var actionUpdateFlushTask: Task<Void, Never>?
    private var pendingActionUpdates: [ActionUpdateKey: PendingActionUpdate] = [:]

    private struct PendingActionUpdate {
        let action: WKWebExtension.Action?
        let context: WKWebExtensionContext
    }

    init(
        directory: URL,
        controllerIdentifier: UUID? = nil,
        controllerConfiguration: WKWebExtensionController.Configuration? = nil,
        websiteDataStore: WKWebsiteDataStore? = nil,
        profileID: UUID? = nil
    ) {
        self.directory = directory
        self.profileID = profileID
        let configuration = controllerConfiguration
            ?? WKWebExtensionController.Configuration(identifier: controllerIdentifier ?? Self.controllerIdentifier)
        if let websiteDataStore {
            configuration.defaultWebsiteDataStore = websiteDataStore
        }
        configuration.webViewConfiguration.applicationNameForUserAgent = "Version/18.4 Safari/605.1.15 cmux"
#if DEBUG
        configuration.webViewConfiguration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserPanel.telemetryHookBootstrapScriptSource
                    + "\n"
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
        loadTask?.cancel()
        loadTask = nil
        actionUpdateFlushTask?.cancel()
        actionUpdateFlushTask = nil
        pendingActionUpdates.removeAll()
        pendingActionInvocations.removeAll()
        lastActionInvocations.removeAll()
        popupWebViews.removeAll()
        for context in loadedContexts {
            _ = try? controller.unload(context)
        }
        loadedContexts.removeAll()
        backgroundLoadErrors.removeAll()
        loadErrors.removeAll()
        tabAdapters.removeAll()
        windowAdapters.removeAll()
        resumeLoadWaiters()
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
        guard loadTask == nil else { return }
        loadTask = Task { await loadExtensions() }
    }

    /// Suspends until the in-flight extension load finishes, bounded by
    /// `timeout` so a hung or pathologically slow load degrades to navigating
    /// without extensions instead of blocking every panel's first navigation
    /// forever. Returns immediately when loading already finished or never
    /// started.
    func waitUntilLoaded(
        timeout: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock()
    ) async {
        guard !isLoaded, loadTask != nil else { return }
        let waiterID = UUID()
        loadWaiters[waiterID] = .pendingRegistration
        let timeoutTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: timeout, tolerance: nil)
            guard !Task.isCancelled else { return }
            self?.resumeLoadWaiter(waiterID)
        }
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
        timeoutTask.cancel()
    }

    /// UI presentation waits for the actual load task. Navigation uses the
    /// bounded waiter above so a slow extension never blocks page navigation,
    /// while the manager and toolbar cannot get stuck with a stale loading copy.
    func waitUntilPresentationReady() async {
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
            isLoaded = true
            resumeLoadWaiters()
        }
        let candidates: [URL]
        do {
            candidates = try await directoryRepository.approvedCandidateURLs(in: directory)
        } catch {
            loadErrors.append((url: directory, error: error))
            return
        }
        guard !Task.isCancelled else { return }
        for url in candidates {
            guard !Task.isCancelled else { return }
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
                loadErrors.append((url: url, error: error))
#if DEBUG
                cmuxDebugLog("browser.extensions.load-failed entry=\(url.lastPathComponent) error=\(error)")
#endif
            }
        }
    }

    func installExtension(from source: URL) async throws -> BrowserWebExtensionInstallReceipt {
        // Serialize installs after startup discovery so the same package cannot
        // be loaded once by each path when a user installs during app launch.
        await waitUntilLoaded()
        // Validate before copying. WKWebExtension accepts either a directory or
        // ZIP archive and parses the manifest plus referenced resources.
        _ = try await WKWebExtension(resourceBaseURL: source)
        let destination = try await directoryRepository.installCandidate(from: source, into: directory)
        do {
            // Approval computes the package digest and rejects symbolic links.
            // Finish it before WebKit can execute any extension resource.
            try await directoryRepository.approveCandidate(at: destination, in: directory)
            let context = try await loadExtension(at: destination)
            return BrowserWebExtensionInstallReceipt(
                name: context.webExtension.displayName ?? destination.deletingPathExtension().lastPathComponent
            )
        } catch {
            await directoryRepository.removeInstalledCandidate(at: destination, from: directory)
            throw error
        }
    }

    func approveInstalledCandidate(_ candidate: URL) async throws {
        try await directoryRepository.approveCandidate(at: candidate, in: directory)
    }

    func installCatalogExtension(_ entry: BrowserWebExtensionCatalogEntry) async throws -> BrowserWebExtensionInstallReceipt {
        let packageURL = try await catalogPackageRepository.download(entry)
        defer {
            Task { await catalogPackageRepository.removeDownloadedPackage(at: packageURL) }
        }
        return try await installExtension(from: packageURL)
    }

    func register(
        panel: BrowserPanel,
        ownerID: UUID,
        activePanelID: @escaping @MainActor () -> UUID?,
        focusPanel: @escaping @MainActor (UUID) -> Void,
        orderedPanelIDs: @escaping @MainActor () -> [UUID] = { [] }
    ) {
        if tabAdapters[panel.id] != nil { return }

        let windowAdapter: BrowserWebExtensionWindowAdapter
        if let existing = windowAdapters[ownerID] {
            windowAdapter = existing
        } else {
            windowAdapter = BrowserWebExtensionWindowAdapter(
                ownerID: ownerID,
                activePanelID: activePanelID,
                focusPanel: focusPanel,
                orderedPanelIDs: orderedPanelIDs
            )
            windowAdapters[ownerID] = windowAdapter
            controller.didOpenWindow(windowAdapter)
        }

        let tabAdapter = BrowserWebExtensionTabAdapter(panel: panel, windowAdapter: windowAdapter)
        tabAdapters[panel.id] = tabAdapter
        windowAdapter.tabAdapters.append(tabAdapter)
        controller.didOpenTab(tabAdapter)
        windowAdapter.lastReportedVisiblePanelIDs = windowAdapter.compactTabs().compactMap { $0.panel?.id }
    }

    func unregister(panelID: UUID) {
        pendingActionInvocations = pendingActionInvocations.filter { $0.key.panelID != panelID }
        lastActionInvocations = lastActionInvocations.filter { $0.key.panelID != panelID }
        guard let tabAdapter = tabAdapters.removeValue(forKey: panelID) else { return }
        controller.didCloseTab(tabAdapter, windowIsClosing: false)
        guard let windowAdapter = tabAdapter.windowAdapter else { return }
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
        focusPanel: @MainActor (UUID) -> Void,
        orderedPanelIDs: @MainActor () -> [UUID]
    )? {
        guard let windowAdapter = tabAdapters[panelID]?.windowAdapter else { return nil }
        return (
            windowAdapter.ownerID,
            windowAdapter.activePanelID,
            windowAdapter.focusPanel,
            windowAdapter.orderedPanelIDs
        )
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

        for panelID in current {
            guard let oldIndex = previous.firstIndex(of: panelID),
                  let newIndex = current.firstIndex(of: panelID),
                  oldIndex != newIndex else {
                continue
            }
            var simulated = previous
            simulated.remove(at: oldIndex)
            simulated.insert(panelID, at: newIndex)
            guard simulated == current,
                  let adapter = tabAdapters[panelID] else {
                continue
            }
            controller.didMoveTab(adapter, from: oldIndex, in: windowAdapter)
            return
        }

        if let panelID = current.first(where: { previous.firstIndex(of: $0) != current.firstIndex(of: $0) }),
           let oldIndex = previous.firstIndex(of: panelID),
           let adapter = tabAdapters[panelID] {
            controller.didMoveTab(adapter, from: oldIndex, in: windowAdapter)
        }
    }

    func tabPropertiesDidChange(
        panelID: UUID,
        properties: WKWebExtension.TabChangedProperties
    ) {
        guard let tabAdapter = tabAdapters[panelID] else { return }
        controller.didChangeTabProperties(properties, for: tabAdapter)
    }

    func activateTab(panelID: UUID, previousPanelID: UUID?) {
        guard let tabAdapter = tabAdapters[panelID] else { return }
        let previousAdapter = previousPanelID.flatMap { tabAdapters[$0] }
        if let previousAdapter, previousAdapter !== tabAdapter {
            controller.didDeselectTabs([previousAdapter])
        }
        controller.didSelectTabs([tabAdapter])
        controller.didActivateTab(tabAdapter, previousActiveTab: previousAdapter)
        controller.didFocusWindow(tabAdapter.windowAdapter)
    }

    func deactivateTab(panelID: UUID) {
        guard let tabAdapter = tabAdapters[panelID] else { return }
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
        } else {
            pendingActionInvocations.removeValue(forKey: key)
        }
        context.performAction(for: tabAdapter)
        return true
    }

    private func loadExtension(at url: URL) async throws -> WKWebExtensionContext {
        let webExtension = try await WKWebExtension(resourceBaseURL: url)
        let context = WKWebExtensionContext(for: webExtension)
        // Stable identifier derived from the install-directory name so
        // per-extension storage survives relaunches.
        context.uniqueIdentifier = "cmux-browser-extension-\(url.lastPathComponent)"
#if DEBUG
        context.isInspectable = true
        context.inspectionName = context.webExtension.displayName ?? url.lastPathComponent
#endif
        grantRequestedPermissions(in: context, for: webExtension)
        try controller.load(context)
        loadedContexts.append(context)
        enqueueActionUpdate(action: nil, context: context, panelID: nil)
        if webExtension.hasBackgroundContent {
            context.loadBackgroundContent { [weak self, weak context] error in
                guard let self, let context else { return }
                if let error {
                    self.backgroundLoadErrors[context.uniqueIdentifier] = error
#if DEBUG
                    cmuxDebugLog(
                        "browser.extensions.background-failed name=\(context.webExtension.displayName ?? context.uniqueIdentifier) " +
                        "error=\(error)"
                    )
#endif
                } else {
                    self.backgroundLoadErrors.removeValue(forKey: context.uniqueIdentifier)
                }
            }
        }
        return context
    }

    func presentationSnapshot(for panelID: UUID? = nil) -> BrowserWebExtensionsPresentationSnapshot {
        let tabAdapter = panelID.flatMap { tabAdapters[$0] }
        return BrowserWebExtensionsPresentationSnapshot(
            state: isLoaded ? .ready : .loading,
            extensions: loadedContexts.map { context in
                let action = tabAdapter.flatMap { context.action(for: $0) }
                return Self.presentationItem(for: context, action: action)
            },
            failures: loadErrors.map { failure in
                BrowserWebExtensionsPresentationSnapshot.Failure(
                    id: failure.url.path,
                    entryName: failure.url.lastPathComponent,
                    message: failure.error.localizedDescription
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
                let backgroundError: Any = backgroundLoadErrors[identifier]
                    .map { String(describing: $0) as Any } ?? NSNull()
                return [
                    "id": identifier,
                    "name": context.webExtension.displayName ?? identifier,
                    "version": context.webExtension.version ?? "",
                    "errors": context.errors.map(Self.errorPayload),
                    "background_error": backgroundError,
                    "has_popup_webview": popupWebViews[identifier]?.webView != nil,
                    "inspectable": context.isInspectable,
                ] as [String: Any]
            },
            "load_errors": loadErrors.map { failure in
                [
                    "entry": failure.url.lastPathComponent,
                    "message": failure.error.localizedDescription,
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
            "failure_reason": nsError.localizedFailureReason ?? "",
            "user_info": nsError.userInfo.mapValues { String(describing: $0) },
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

    private static func presentationItem(
        for context: WKWebExtensionContext,
        action: WKWebExtension.Action?
    ) -> BrowserWebExtensionsPresentationSnapshot.Item {
        BrowserWebExtensionsPresentationSnapshot.Item(
            id: context.uniqueIdentifier,
            name: context.webExtension.displayName ?? context.uniqueIdentifier,
            hasAction: definesAction(context.webExtension),
            isActionEnabled: action?.isEnabled ?? definesAction(context.webExtension),
            badgeText: action?.badgeText ?? "",
            iconData: presentationIconData(for: action, webExtension: context.webExtension)
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
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.actionUpdateFlushTask = nil
            let updates = self.pendingActionUpdates
            self.pendingActionUpdates.removeAll()
            for (key, update) in updates {
                let item = Self.presentationItem(for: update.context, action: update.action)
                NotificationCenter.default.post(
                    name: .browserWebExtensionActionDidChange,
                    object: key.extensionIdentifier,
                    userInfo: [
                        BrowserWebExtensionNotificationKey.panelID: key.panelID ?? NSNull(),
                        BrowserWebExtensionNotificationKey.profileID: self.profileID ?? NSNull(),
                        BrowserWebExtensionNotificationKey.item: item,
                    ]
                )
            }
        }
    }

    private static func presentationIconData(
        for action: WKWebExtension.Action?,
        webExtension: WKWebExtension
    ) -> Data? {
        let size = CGSize(width: 32, height: 32)
        guard let image = action?.icon(for: size)
                ?? webExtension.actionIcon(for: size)
                ?? webExtension.icon(for: size),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
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
        presentActionPopup action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let popover = action.popupPopover,
              let anchor = popupAnchor(for: action, extensionContext: extensionContext) else {
            completionHandler(BrowserWebExtensionActionError.missingPopupAnchor)
            return
        }
        popover.behavior = .transient
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
        if let webView = action.popupWebView {
            popupWebViews[extensionContext.uniqueIdentifier] = WeakPopupWebView(webView)
        }
        completionHandler(nil)
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
    // Runtime calls request optional access, which cmux denies without opening
    // a modal alert. A future inline permission surface can selectively grant it.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions.intersection(extensionContext.webExtension.requestedPermissions), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let declared = extensionContext.webExtension.allRequestedMatchPatterns
        let allowed = urls.filter { url in declared.contains { $0.matches(url) } }
        completionHandler(allowed, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let declared = extensionContext.webExtension.allRequestedMatchPatterns
        let allowed = matchPatterns.filter { requested in declared.contains { $0.matches(requested) } }
        completionHandler(allowed, nil)
    }

    private func orderedWindowAdapters() -> [BrowserWebExtensionWindowAdapter] {
        let live = windowAdapters.values.filter { !$0.compactTabs().isEmpty }
        return live.sorted { lhs, rhs in
            let lhsKey = lhs.compactTabs().contains { $0.panel?.webView.window === NSApp.keyWindow }
            let rhsKey = rhs.compactTabs().contains { $0.panel?.webView.window === NSApp.keyWindow }
            if lhsKey != rhsKey { return lhsKey }
            return lhs.ownerID.uuidString < rhs.ownerID.uuidString
        }
    }

    private func focusedWindowAdapter() -> BrowserWebExtensionWindowAdapter? {
        guard NSApp.isActive, let keyWindow = NSApp.keyWindow else { return nil }
        return orderedWindowAdapters().first { adapter in
            adapter.compactTabs().contains { $0.panel?.webView.window === keyWindow }
        }
    }
}

extension Notification.Name {
    static let browserWebExtensionActionDidChange = Notification.Name(
        "cmux.browserWebExtensionActionDidChange"
    )
}

enum BrowserWebExtensionNotificationKey {
    static let panelID = "panelID"
    static let profileID = "profileID"
    static let item = "item"
}

@available(macOS 15.4, *)
private enum BrowserWebExtensionActionError: LocalizedError {
    case missingPopupAnchor

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
    case webViewNotFound(String)
    case popupNotOpen(String)
    case debugBuildRequired

    var errorDescription: String? {
        switch self {
        case .extensionNotFound(let identifier):
            return "Extension not found: \(identifier)"
        case .webViewNotFound(let identifier):
            return "Extension webview not found: \(identifier)"
        case .popupNotOpen(let name):
            return "Open the \(name) extension popup before accessing its webview."
        case .debugBuildRequired:
            return "Extension JavaScript inspection is available only in cmux development builds."
        }
    }
}
