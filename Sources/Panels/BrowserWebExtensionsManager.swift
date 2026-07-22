import AppKit
import CmuxBrowser
import CryptoKit
import Foundation
import ImageIO
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
/// manifest permissions and match patterns. Declared optional requests require a
/// separate user decision and are persisted per browser profile.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionsManager: NSObject {
    static let actionPopupPreferredEdge: NSRectEdge = .minY

    static func safariCompatibleApplicationName(
        safariVersionProvider: () -> String?,
        operatingSystemVersion: OperatingSystemVersion
    ) -> String {
        let fallbackVersion = "\(operatingSystemVersion.majorVersion).\(operatingSystemVersion.minorVersion)"
        let suppliedVersion = safariVersionProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = suppliedVersion.flatMap { candidate in
            candidate.range(of: #"^\d+(?:\.\d+)*$"#, options: .regularExpression) != nil
                ? candidate
                : nil
        } ?? fallbackVersion
        return "Version/\(version) Safari/605.1.15 cmux"
    }

    static func safariCompatibleApplicationName() -> String {
        safariCompatibleApplicationName(
            safariVersionProvider: installedSafariVersion,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    private static func installedSafariVersion() -> String? {
        Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// System WebKit advertises the `notifications` manifest permission but
    /// omits the JavaScript namespace outside its private test mode. Extensions
    /// such as 1Password register notification listeners during startup without
    /// feature detection, so the missing namespace aborts their background page.
    /// WebKit also omits `webNavigation.onCreatedNavigationTarget`, which
    /// 1Password registers during the same startup sequence. Keep these small
    /// compatibility surfaces until WebKit ships the public APIs.
    static let notificationsCompatibilityScriptSource = #"""
    (() => {
      const notifications = new Map();
      const dispatchEvent = Symbol('dispatchEvent');
      const makeEvent = () => {
        const listeners = new Set();
        return {
          addListener(listener) { if (typeof listener === 'function') listeners.add(listener); },
          removeListener(listener) { listeners.delete(listener); },
          hasListener(listener) { return listeners.has(listener); },
          hasListeners() { return listeners.size > 0; },
          [dispatchEvent](...args) {
            for (const listener of listeners) listener(...args);
          }
        };
      };
      const navigationTargetEvent = makeEvent();
      const pinNestedNamespace = (namespace, property) => {
        if (!namespace) return undefined;
        let value;
        try { value = namespace[property]; } catch (_) { return undefined; }
        if (!value) return undefined;
        try {
          const descriptor = Object.getOwnPropertyDescriptor(namespace, property);
          if (descriptor?.configurable) {
            // JavaScriptCore can garbage-collect and recreate WebKit's lazy
            // nested API wrapper, dropping expandos. Pin the exact wrapper
            // before adding a compatibility member so its identity survives.
            Object.defineProperty(namespace, property, {
              configurable: false,
              enumerable: descriptor.enumerable,
              writable: false,
              value
            });
          }
        } catch (_) {}
        return value;
      };
      const complete = (value, callback) => {
        if (typeof callback === 'function') queueMicrotask(() => callback(value));
        return Promise.resolve(value);
      };
      const makeDisconnectedNativePort = application => {
        const messageEvent = makeEvent();
        const disconnectEvent = makeEvent();
        const port = {
          name: application || '',
          error: new Error('No such native application'),
          onMessage: messageEvent,
          onDisconnect: disconnectEvent,
          postMessage() {},
          disconnect() {}
        };
        queueMicrotask(() => {
          disconnectEvent[dispatchEvent](port);
        });
        return port;
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
          if (!namespace) continue;
          if (!namespace.notifications) {
            try {
              Object.defineProperty(namespace, 'notifications', {
                configurable: true,
                enumerable: true,
                value: api
              });
            } catch (_) {}
          }
          const webNavigation = pinNestedNamespace(namespace, 'webNavigation');
          if (webNavigation && !webNavigation.onCreatedNavigationTarget) {
            try {
              Object.defineProperty(webNavigation, 'onCreatedNavigationTarget', {
                configurable: false,
                enumerable: true,
                value: navigationTargetEvent
              });
            } catch (_) {}
          }
          if (namespace.runtime && !namespace.runtime.connectNative) {
            try {
              const runtime = pinNestedNamespace(namespace, 'runtime');
              Object.defineProperty(runtime, 'connectNative', {
                configurable: false,
                enumerable: true,
                value: makeDisconnectedNativePort
              });
            } catch (_) {}
          }
        }
      };
      install();
      queueMicrotask(install);
      if (document.readyState === 'loading') {
        document.addEventListener('readystatechange', () => {
          if (document.readyState !== 'loading') install();
        }, { once: true });
      }
    })();
    """#

    typealias AppExtensionLoader = @MainActor (Bundle) async throws -> WKWebExtension
    typealias ActionPerformer = @MainActor (WKWebExtensionContext, BrowserWebExtensionTabAdapter) -> Void
    typealias PopupHandoffDeadline = @MainActor @Sendable () async throws -> Void
    typealias SafariAppVerifier = @Sendable (URL) async throws -> BrowserWebExtensionSafariAppIdentity
    typealias PostManagementCommitHook = @MainActor @Sendable () async throws -> Void
    typealias PermissionPromptPresenter = @MainActor @Sendable (
        BrowserWebExtensionPermissionRequest,
        NSWindow?
    ) async -> BrowserWebExtensionPermissionDecision

    @MainActor
    private final class PendingPermissionResolution {
        private var isFinished = false
        private let deny: () -> Void

        init(deny: @escaping () -> Void) {
            self.deny = deny
        }

        func finish(_ operation: () -> Void) {
            guard !isFinished else { return }
            isFinished = true
            operation()
        }

        func finishDenying() {
            finish(deny)
        }
    }

    private final class PendingActionInvocation {
        let id = UUID()
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

    /// Owns every object WebKit and AppKit can touch while an action popover is
    /// visible or closing. The manager and token intentionally retain each
    /// other until the close callback has returned and one main-actor turn has
    /// completed, so profile/context teardown cannot race deferred KVO cleanup.
    @MainActor
    private final class PresentedActionPopup: NSObject, NSPopoverDelegate {
        let popover: NSPopover
        let extensionIdentifier: String
        let panelID: UUID?
        var invocationKey: ActionInvocationKey?
        let anchorView: NSView?

        private let action: WKWebExtension.Action
        private let context: WKWebExtensionContext
        private let controller: WKWebExtensionController
        private let tabAdapter: BrowserWebExtensionTabAdapter?
        private let popupWebView: WKWebView?
        private var placementLock: BrowserWebExtensionPopupPlacementLock?
        private var owner: BrowserWebExtensionsManager?
        private var didBeginCloseCompletion = false
        private(set) var isLifecycleClose = false

        init(
            popover: NSPopover,
            extensionIdentifier: String,
            panelID: UUID?,
            invocationKey: ActionInvocationKey?,
            anchorView: NSView?,
            action: WKWebExtension.Action,
            context: WKWebExtensionContext,
            controller: WKWebExtensionController,
            tabAdapter: BrowserWebExtensionTabAdapter?,
            popupWebView: WKWebView?,
            placementLock: BrowserWebExtensionPopupPlacementLock?,
            owner: BrowserWebExtensionsManager
        ) {
            self.popover = popover
            self.extensionIdentifier = extensionIdentifier
            self.panelID = panelID
            self.invocationKey = invocationKey
            self.anchorView = anchorView
            self.action = action
            self.context = context
            self.controller = controller
            self.tabAdapter = tabAdapter
            self.popupWebView = popupWebView
            self.placementLock = placementLock
            self.owner = owner
            super.init()
            popover.delegate = self
        }

        func attachPlacementLock(_ placementLock: BrowserWebExtensionPopupPlacementLock) {
            guard !didBeginCloseCompletion else {
                placementLock.stop()
                return
            }
            self.placementLock = placementLock
        }

        func requestLifecycleClose() {
            isLifecycleClose = true
            if popover.isShown {
                // Lifecycle teardown must not be vetoed by a delegate, nested
                // popover, or child window. `performClose` can refuse all
                // three, leaving the WebKit ownership cycle alive forever.
                popover.close()
            }
            if !popover.isShown {
                beginCloseCompletion(event: nil)
            }
        }

        func popoverDidClose(_ notification: Notification) {
            beginCloseCompletion(event: NSApp.currentEvent)
        }

        private func beginCloseCompletion(event: NSEvent?) {
            guard !didBeginCloseCompletion else { return }
            didBeginCloseCompletion = true
            placementLock?.stop()
            owner?.presentedPopupDidClose(self, event: event)
            DispatchQueue.main.async { [self] in
                // AppKit can retain deferred observations until its close
                // callback returns. A main-queue hop guarantees that boundary;
                // Task.yield() does not.
                popover.delegate = nil
                let retainedOwner = owner
                owner = nil
                retainedOwner?.presentedPopupDidQuiesce(self)
            }
        }
    }

    private final class WeakPopupWebView {
        weak var webView: WKWebView?

        init(_ webView: WKWebView) {
            self.webView = webView
        }
    }

    private final class ExtensionPageContentControllerRegistration {
        weak var userContentController: WKUserContentController?
        let extensionIdentifier: String

        init(
            userContentController: WKUserContentController,
            extensionIdentifier: String
        ) {
            self.userContentController = userContentController
            self.extensionIdentifier = extensionIdentifier
        }
    }

    /// Fixed controller identifier so extension storage (`browser.storage`,
    /// declarativeNetRequest state) persists across launches.
    private static let controllerIdentifier = UUID(uuidString: "3B7D2A9E-5C41-4F8A-B6D0-9E2C7A51F3D8")!

    let controller: WKWebExtensionController
    let directory: URL
    let profileID: UUID?
    let profileRuntime: BrowserWebExtensionProfileRuntime
    private let directoryRepository: BrowserWebExtensionDirectoryRepository
    private let postManagementCommitHook: PostManagementCommitHook
    private let catalogPackageRepository: BrowserWebExtensionCatalogPackageRepository
    private let appExtensionLoader: AppExtensionLoader
    private let performExtensionAction: ActionPerformer
    private let waitForPopupHandoffDeadline: PopupHandoffDeadline
    private let verifySafariAppExtension: SafariAppVerifier
    private let presentPermissionPrompt: PermissionPromptPresenter
    var isLoaded: Bool {
        switch profileRuntime.phase {
        case .ready, .degraded:
            return true
        case .idle, .loading, .shutDown:
            return false
        }
    }
    private(set) var loadedContexts: [WKWebExtensionContext] = []
    private(set) var loadErrors: [(url: URL, error: any Error)] = []
    private var toolbarPinnedExtensionIdentifiers = Set<String>()
    private var tabAdapters: [UUID: BrowserWebExtensionTabAdapter] = [:]
    private var windowAdapters: [UUID: BrowserWebExtensionWindowAdapter] = [:]
    private var popupWindowAdapters: [UUID: BrowserWebExtensionPopupWindowAdapter] = [:]
    private var pendingActionInvocations: [ActionInvocationKey: [PendingActionInvocation]] = [:]
    private var lastActionInvocations: [ActionInvocationKey: PendingActionInvocation] = [:]
    private var popupHandoffDeadlineTasks: [ActionInvocationKey: Task<Void, Never>] = [:]
    private var actionsAwaitingReadyPopup = Set<ActionInvocationKey>()
    private var expiredPopupHandoffs = Set<ActionInvocationKey>()
    private var dismissedPopupKeys = Set<ActionInvocationKey>()
    private var popupClosuresRequestedByActionButton = Set<ActionInvocationKey>()
    private var presentedPopups: [ObjectIdentifier: PresentedActionPopup] = [:]
    private var popupWebViews: [String: WeakPopupWebView] = [:]
    private var extensionPageContentControllers: [
        ObjectIdentifier: ExtensionPageContentControllerRegistration
    ] = [:]
#if DEBUG
    private var debugSyntheticPopupKeys: [ObjectIdentifier: ActionInvocationKey] = [:]
#endif
    private var actionUpdateFlushTask: Task<Void, Never>?
    private var pendingActionUpdates: [ActionUpdateKey: PendingActionUpdate] = [:]
    private var installTasks: [UUID: Task<BrowserWebExtensionInstallReceipt, any Error>] = [:]
    private var preparedInstalls: [UUID: PreparedInstall] = [:]
    private var managedRecordIDsByContextIdentifier: [String: String] = [:]
    private var managedRecords: [String: BrowserWebExtensionManagedRecord] = [:]
    private var failedManagedRecordIDs = Set<String>()
    private var managedLoadFailureURLPaths = Set<String>()
    private var permissionPromptTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingPermissionResolutions: [UUID: PendingPermissionResolution] = [:]
    private var permissionRequestContextIdentifiers: [UUID: ObjectIdentifier] = [:]
    private var permissionPromptTail: Task<Void, Never>?
    private(set) var isShutDown = false
    private var didFinalizeShutdown = false
    private var pendingPanelUnregistrations = Set<UUID>()
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var popupQuiescenceWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
#if DEBUG
    private(set) var debugDidOpenTabEventCount = 0
    private(set) var debugDidCloseTabEventCount = 0
#endif

    private struct PendingActionUpdate {
        let action: WKWebExtension.Action?
        let context: WKWebExtensionContext
    }

    private struct PreparedInstall {
        enum Source {
            case package(
                url: URL,
                catalogID: String?,
                cleanupURL: URL?
            )
            case safariApp(BrowserWebExtensionAppExtensionReference)
        }

        let preview: BrowserWebExtensionInstallPreview
        let logicalID: String
        let source: Source
        let expectedPackageDigest: String?
        let expectedPreviousRecord: BrowserWebExtensionManagedRecord?
    }

    private struct PresentationIconCacheEntry {
        let signature: String
        let data: Data?
    }

    private var presentationIconCache: [ActionUpdateKey: PresentationIconCacheEntry] = [:]
    private var actionFailures: [ActionUpdateKey: BrowserWebExtensionActionFailure] = [:]

    init(
        directory: URL,
        controllerIdentifier: UUID? = nil,
        controllerConfiguration: WKWebExtensionController.Configuration? = nil,
        websiteDataStore: WKWebsiteDataStore? = nil,
        profileID: UUID? = nil,
        profileRuntime: BrowserWebExtensionProfileRuntime? = nil,
        directoryRepository: BrowserWebExtensionDirectoryRepository = BrowserWebExtensionDirectoryRepository(),
        catalogPackageRepository: BrowserWebExtensionCatalogPackageRepository = BrowserWebExtensionCatalogPackageRepository(),
        performExtensionAction: @escaping ActionPerformer = { context, tab in
            context.performAction(for: tab)
        },
        waitForPopupHandoffDeadline: @escaping PopupHandoffDeadline = {
            try await ContinuousClock().sleep(for: .seconds(3))
        },
        verifySafariAppExtension: @escaping SafariAppVerifier = { extensionURL in
            try await Task.detached(priority: .userInitiated) {
                try BrowserWebExtensionCodeSignatureVerifier()
                    .verifySafariExtension(at: extensionURL)
                    .identity
            }.value
        },
        permissionPromptPresenter: @escaping PermissionPromptPresenter = { request, window in
            await BrowserWebExtensionPermissionPromptPresenter().decision(
                for: request,
                window: window
            )
        },
        postManagementCommitHook: @escaping PostManagementCommitHook = {},
        appExtensionLoader: @escaping AppExtensionLoader = { bundle in
            try await WKWebExtension(appExtensionBundle: bundle)
        }
    ) {
        self.directory = directory
        self.profileID = profileID
        self.directoryRepository = directoryRepository
        self.postManagementCommitHook = postManagementCommitHook
        self.catalogPackageRepository = catalogPackageRepository
        self.appExtensionLoader = appExtensionLoader
        self.performExtensionAction = performExtensionAction
        self.waitForPopupHandoffDeadline = waitForPopupHandoffDeadline
        self.verifySafariAppExtension = verifySafariAppExtension
        self.presentPermissionPrompt = permissionPromptPresenter
        let runtimeProfileID = profileID ?? controllerIdentifier ?? Self.controllerIdentifier
        self.profileRuntime = profileRuntime ?? BrowserWebExtensionProfileRuntime(
            profileID: runtimeProfileID,
            waitForDeadline: {
                // A bounded, cancellable deadline prevents one broken extension
                // from blocking normal navigation. It never polls for readiness.
                try await ContinuousClock().sleep(for: .seconds(5))
            }
        )
        let configuration = controllerConfiguration
            ?? WKWebExtensionController.Configuration(identifier: controllerIdentifier ?? Self.controllerIdentifier)
        if let websiteDataStore {
            configuration.defaultWebsiteDataStore = websiteDataStore
        }
        configuration.webViewConfiguration.applicationNameForUserAgent = Self.safariCompatibleApplicationName()
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
        profileRuntime.shutdown()
        for task in installTasks.values { task.cancel() }
        installTasks.removeAll()
        for prepared in preparedInstalls.values {
            if case .package(_, _, let cleanupURL) = prepared.source,
               let cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL.deletingLastPathComponent())
            }
        }
        preparedInstalls.removeAll()
        for resolution in pendingPermissionResolutions.values {
            resolution.finishDenying()
        }
        pendingPermissionResolutions.removeAll()
        permissionRequestContextIdentifiers.removeAll()
        for task in permissionPromptTasks.values { task.cancel() }
        permissionPromptTasks.removeAll()
        permissionPromptTail?.cancel()
        permissionPromptTail = nil
        actionUpdateFlushTask?.cancel()
        actionUpdateFlushTask = nil
        pendingActionUpdates.removeAll()
        presentationIconCache.removeAll()
        actionFailures.removeAll()
        pendingActionInvocations.removeAll()
        lastActionInvocations.removeAll()
        for task in popupHandoffDeadlineTasks.values { task.cancel() }
        popupHandoffDeadlineTasks.removeAll()
        actionsAwaitingReadyPopup.removeAll()
        expiredPopupHandoffs.removeAll()
        dismissedPopupKeys.removeAll()
        popupClosuresRequestedByActionButton.removeAll()
#if DEBUG
        debugSyntheticPopupKeys.removeAll()
#endif
        for popup in Array(presentedPopups.values) {
            popup.requestLifecycleClose()
        }
        if presentedPopups.isEmpty {
            finalizeShutdown()
        }
    }

    private func finalizeShutdown() {
        guard isShutDown, !didFinalizeShutdown, presentedPopups.isEmpty else { return }
        didFinalizeShutdown = true
        popupWebViews.removeAll()
        for context in loadedContexts {
            _ = try? unloadContext(context)
        }
        loadedContexts.removeAll()
        extensionPageContentControllers.removeAll()
        managedRecordIDsByContextIdentifier.removeAll()
        managedRecords.removeAll()
        toolbarPinnedExtensionIdentifiers.removeAll()
        loadErrors.removeAll()
        tabAdapters.removeAll()
        windowAdapters.removeAll()
        popupWindowAdapters.removeAll()
        pendingPanelUnregistrations.removeAll()
        controller.delegate = nil
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForShutdownFinalization() async {
        guard !didFinalizeShutdown else { return }
        await withCheckedContinuation { continuation in
            if didFinalizeShutdown {
                continuation.resume()
            } else {
                shutdownWaiters.append(continuation)
            }
        }
    }

    func shutdownAndWait() async {
        shutdown()
        await waitForShutdownFinalization()
    }

    func shutdownAndRemoveDirectory() async {
        await shutdownAndWait()
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
        guard !isShutDown, profileRuntime.phase == .idle else { return }
        startLoadingAttempt()
    }

    func retryLoading() {
        guard !isShutDown, !profileRuntime.isLoadAttemptInFlight else { return }
        switch profileRuntime.phase {
        case .degraded:
            startLoadingAttempt()
        case .idle:
            startLoading()
        case .loading, .ready, .shutDown:
            break
        }
    }

    private func startLoadingAttempt() {
        for context in loadedContexts {
            cancelPermissionPrompts(for: context)
            _ = try? unloadContext(context)
        }
        loadedContexts.removeAll()
        extensionPageContentControllers.removeAll()
        loadErrors.removeAll()
        failedManagedRecordIDs.removeAll()
        managedLoadFailureURLPaths.removeAll()
        profileRuntime.start { @MainActor [weak self] in
            guard let self, !self.isShutDown else {
                return .degraded(.loadFailed)
            }
            return await self.loadApprovedExtensions()
        }
    }

    /// Suspends until the in-flight extension load finishes. Callers can cancel
    /// their own wait, but readiness never falls back to an elapsed-time guess:
    /// first navigation starts only after every approved context is registered.
    func waitUntilLoaded() async {
        startLoading()
        guard !isLoaded else { return }
        for await update in profileRuntime.updates() {
            guard !Task.isCancelled else { return }
            guard case .phaseChanged(let phase) = update else { continue }
            switch phase {
            case .ready, .degraded, .shutDown:
                return
            case .idle, .loading:
                continue
            }
        }
    }

    /// UI presentation waits for the same manager-owned readiness invariant as
    /// navigation and installation.
    func waitUntilPresentationReady() async {
        await waitUntilLoaded()
    }

    func loadExtensions() async {
        startLoading()
        await waitUntilLoaded()
    }

    private func loadApprovedExtensions() async -> BrowserWebExtensionLoadOutcome {
        guard !isShutDown else { return .degraded(.loadFailed) }
        let discovery: BrowserWebExtensionManagedDiscovery
        do {
            let ledger = try await directoryRepository.managementLedger(in: directory)
            guard !Task.isCancelled, !isShutDown else { return .degraded(.loadFailed) }
            managedRecords = ledger.records
            toolbarPinnedExtensionIdentifiers = Set(ledger.records.values.compactMap { record in
                record.isEnabled && record.isToolbarPinned
                    ? Self.contextIdentifier(for: record)
                    : nil
            })
            await removeOrphanedManagedData(authoritativeRecords: ledger.records.values)
            try await directoryRepository.removeUnreferencedManagedPackages(in: directory)
            guard !Task.isCancelled, !isShutDown else { return .degraded(.loadFailed) }
            discovery = try await directoryRepository.managedInstallations(in: directory)
        } catch {
            guard !isShutDown, !Task.isCancelled else { return .degraded(.loadFailed) }
            loadErrors.append((url: directory, error: error))
            profileRuntime.invalidateSnapshot()
            return .degraded(.loadFailed)
        }
        failedManagedRecordIDs.formUnion(discovery.failures.map(\.recordID))
        managedLoadFailureURLPaths.formUnion(discovery.failures.map { failure in
            directory.appendingPathComponent(failure.entryName).standardizedFileURL.path
        })
        loadErrors.append(contentsOf: discovery.failures.map { failure in
            (
                url: directory.appendingPathComponent(failure.entryName),
                error: BrowserWebExtensionApprovalValidationError(
                    message: String(
                        localized: "browser.extensions.load.failed",
                        defaultValue: "The extension could not be loaded."
                    )
                )
            )
        })
        guard !Task.isCancelled, !isShutDown else { return .degraded(.loadFailed) }
        for installation in discovery.installations {
            guard !Task.isCancelled, !isShutDown else { return .degraded(.loadFailed) }
            do {
                let context = try await loadManagedRecord(installation.record)
#if DEBUG
                cmuxDebugLog(
                    "browser.extensions.loaded name=\(context.webExtension.displayName ?? installation.record.displayName) " +
                    "permissions=\(context.webExtension.requestedPermissions.count) " +
                    "patterns=\(context.webExtension.allRequestedMatchPatterns.count)"
                )
#endif
            } catch {
                guard !isShutDown, !Task.isCancelled else { return .degraded(.loadFailed) }
                failedManagedRecordIDs.insert(installation.record.id)
                managedLoadFailureURLPaths.insert(installation.resourceURL.standardizedFileURL.path)
                loadErrors.append((url: installation.resourceURL, error: error))
#if DEBUG
                cmuxDebugLog(
                    "browser.extensions.load-failed entry=\(installation.resourceURL.lastPathComponent) " +
                    "domain=\((error as NSError).domain) code=\((error as NSError).code)"
                )
#endif
            }
        }
        profileRuntime.invalidateSnapshot()
        return .ready
    }

    private func removeOrphanedManagedData(
        authoritativeRecords: Dictionary<String, BrowserWebExtensionManagedRecord>.Values
    ) async {
        let authoritativeContextIdentifiers = Set(authoritativeRecords.map {
            Self.contextIdentifier(for: $0)
        })
        let dataTypes = WKWebExtensionController.allExtensionDataTypes
        let orphanedRecords = await controller.dataRecords(ofTypes: dataTypes).filter { record in
            record.uniqueIdentifier.hasPrefix(Self.managedContextIdentifierPrefix)
                && !authoritativeContextIdentifiers.contains(record.uniqueIdentifier)
        }
        guard !orphanedRecords.isEmpty else { return }
        await controller.removeData(ofTypes: dataTypes, from: orphanedRecords)
    }

    func prepareInstall(from source: URL) async throws -> BrowserWebExtensionInstallPreview {
        try await prepareInstall(
            from: source,
            archivePolicy: .reject,
            catalogID: nil,
            cleanupURL: nil
        )
    }

    func prepareCatalogInstall(
        _ entry: BrowserWebExtensionCatalogEntry
    ) async throws -> BrowserWebExtensionInstallPreview {
        try requireActive()
        let packageURL = try await catalogPackageRepository.download(entry)
        do {
            return try await prepareInstall(
                from: packageURL,
                archivePolicy: .verifiedCatalog(
                    expectedSHA256: entry.packageSHA256,
                    limits: entry.archiveLimits
                ),
                catalogID: entry.id,
                cleanupURL: packageURL
            )
        } catch {
            await catalogPackageRepository.removeDownloadedPackage(at: packageURL)
            throw error
        }
    }

    private func prepareInstall(
        from source: URL,
        archivePolicy: BrowserWebExtensionArchivePolicy,
        catalogID: String?,
        cleanupURL: URL?
    ) async throws -> BrowserWebExtensionInstallPreview {
        try requireActive()
        await waitUntilLoaded()
        try requireActive()
        let installSource = try await directoryRepository.resolveInstallSource(
            at: source,
            archivePolicy: archivePolicy
        )
        let trustedArchiveDigest: String? = if case .verifiedCatalog(let expectedSHA256, _) = archivePolicy {
            expectedSHA256
        } else {
            nil
        }
        try requireActive()
        let ledger = try await directoryRepository.managementLedger(in: directory)
        let preparedSource: PreparedInstall.Source
        let logicalID: String
        let previousRecord: BrowserWebExtensionManagedRecord?
        let webExtension: WKWebExtension
        let expectedPackageDigest: String?
        switch installSource {
        case .managedPackage(let packageURL, let installationName):
            try await directoryRepository.validatePackageSize(at: packageURL)
            try requireActive()
            let digestBeforeReview = try await directoryRepository.digestForManagedPackage(at: packageURL)
            if let trustedArchiveDigest,
               digestBeforeReview.caseInsensitiveCompare(trustedArchiveDigest) != .orderedSame {
                throw BrowserWebExtensionInstallError.integrityMismatch
            }
            try requireActive()
            webExtension = try await WKWebExtension(resourceBaseURL: packageURL)
            try validateLoadableManifest(webExtension)
            try requireActive()
            let digestAfterReview = try await directoryRepository.digestForManagedPackage(at: packageURL)
            guard digestBeforeReview.caseInsensitiveCompare(digestAfterReview) == .orderedSame,
                  trustedArchiveDigest == nil
                    || digestAfterReview.caseInsensitiveCompare(trustedArchiveDigest!) == .orderedSame else {
                throw BrowserWebExtensionInstallError.integrityMismatch
            }
            expectedPackageDigest = trustedArchiveDigest ?? digestAfterReview
            if let catalogID {
                previousRecord = try uniqueManagedRecord(in: ledger) { record in
                    guard case .catalogArchive(_, _, let installedCatalogID) = record.source else {
                        return false
                    }
                    return installedCatalogID == catalogID
                }
                let canonicalID = BrowserWebExtensionManagementIdentity.catalog(id: catalogID)
                if previousRecord == nil,
                   ledger.records[canonicalID] != nil {
                    throw BrowserWebExtensionInstallError.installPreviewExpired
                }
                logicalID = previousRecord?.id ?? canonicalID
            } else {
                previousRecord = try uniqueManagedRecord(in: ledger) { record in
                    guard case .directory(_, let installedDigest) = record.source else {
                        return false
                    }
                    return installedDigest.caseInsensitiveCompare(digestAfterReview) == .orderedSame
                }
                if let previousRecord {
                    logicalID = previousRecord.id
                } else {
                    var candidateID: String
                    repeat {
                        candidateID = BrowserWebExtensionManagementIdentity.disk()
                    } while ledger.records[candidateID] != nil
                    logicalID = candidateID
                }
            }
            preparedSource = .package(
                url: packageURL,
                catalogID: catalogID,
                cleanupURL: cleanupURL
            )
        case .appExtensionBundle(let reference):
            _ = try await verifySafariAppExtension(reference.bundleURL)
            try requireActive()
            webExtension = try await self.webExtension(for: reference)
            try validateLoadableManifest(webExtension)
            try requireActive()
            expectedPackageDigest = nil
            previousRecord = try uniqueManagedRecord(in: ledger) { record in
                guard case .safariApp(let installedReference) = record.source else {
                    return false
                }
                return installedReference.bundleIdentifier == reference.bundleIdentifier
            }
            let canonicalID = BrowserWebExtensionManagementIdentity.safariApp(
                bundleIdentifier: reference.bundleIdentifier
            )
            if previousRecord == nil,
               ledger.records[canonicalID] != nil {
                throw BrowserWebExtensionInstallError.installPreviewExpired
            }
            logicalID = previousRecord?.id ?? canonicalID
            preparedSource = .safariApp(reference)
        }
        let previewID = UUID()
        let optionalPatterns = webExtension.optionalPermissionMatchPatterns
        let requiredPatterns = webExtension.allRequestedMatchPatterns
            .union(webExtension.requestedPermissionMatchPatterns)
            .subtracting(optionalPatterns)
        let notices: [BrowserWebExtensionCapabilityNotice]
        if catalogID == "1password" {
            notices = [.browserOnlyNoDesktopBridge]
        } else {
            notices = []
        }
        let preview = BrowserWebExtensionInstallPreview(
            id: previewID,
            name: webExtension.displayName ?? source.deletingPathExtension().lastPathComponent,
            version: webExtension.version ?? "",
            requiredPermissions: webExtension.requestedPermissions.map(\.rawValue),
            requiredHosts: requiredPatterns.map(\.string),
            optionalPermissions: webExtension.optionalPermissions.map(\.rawValue),
            optionalHosts: optionalPatterns.map(\.string),
            isUpdate: previousRecord != nil,
            capabilityNotices: notices
        )
        preparedInstalls[previewID] = PreparedInstall(
            preview: preview,
            logicalID: logicalID,
            source: preparedSource,
            expectedPackageDigest: expectedPackageDigest,
            expectedPreviousRecord: previousRecord
        )
        return preview
    }

    private func uniqueManagedRecord(
        in ledger: BrowserWebExtensionManagementLedger,
        matching predicate: (BrowserWebExtensionManagedRecord) -> Bool
    ) throws -> BrowserWebExtensionManagedRecord? {
        let matches = ledger.records.values.filter(predicate)
        guard matches.count <= 1 else {
            throw BrowserWebExtensionInstallError.installPreviewExpired
        }
        return matches.first
    }

    func cancelPreparedInstall(id: UUID) async {
        guard let prepared = preparedInstalls.removeValue(forKey: id) else { return }
        await cleanupPreparedInstall(prepared)
    }

    func confirmPreparedInstall(
        id: UUID,
        grantedOptionalPermissions: Set<String> = [],
        grantedOptionalHosts: Set<String> = []
    ) async throws -> BrowserWebExtensionInstallReceipt {
        guard let prepared = preparedInstalls.removeValue(forKey: id) else {
            throw BrowserWebExtensionInstallError.installPreviewExpired
        }
        do {
            let receipt = try await runTrackedInstall { manager in
                try await manager.installPrepared(
                    prepared,
                    grantedOptionalPermissions: grantedOptionalPermissions,
                    grantedOptionalHosts: grantedOptionalHosts
                )
            }
            await cleanupPreparedInstall(prepared)
            return receipt
        } catch {
            await cleanupPreparedInstall(prepared)
            throw error
        }
    }

#if DEBUG
    /// Test-only convenience that still exercises the production review and
    /// content-addressed confirmation pipeline. No product entrypoint calls it.
    func installExtension(from source: URL) async throws -> BrowserWebExtensionInstallReceipt {
        let preview = try await prepareInstall(from: source)
        return try await confirmPreparedInstall(id: preview.id)
    }

    /// Test-only catalog convenience matching ``installExtension(from:)``.
    func installCatalogExtension(
        _ entry: BrowserWebExtensionCatalogEntry
    ) async throws -> BrowserWebExtensionInstallReceipt {
        let preview = try await prepareCatalogInstall(entry)
        return try await confirmPreparedInstall(id: preview.id)
    }
#endif

    private func cleanupPreparedInstall(_ prepared: PreparedInstall) async {
        if case .package(_, _, let cleanupURL) = prepared.source,
           let cleanupURL {
            await catalogPackageRepository.removeDownloadedPackage(at: cleanupURL)
        }
    }

    private func installPrepared(
        _ prepared: PreparedInstall,
        grantedOptionalPermissions: Set<String>,
        grantedOptionalHosts: Set<String>
    ) async throws -> BrowserWebExtensionInstallReceipt {
        try requireActive()
        let ledger = try await directoryRepository.managementLedger(in: directory)
        let previousRecord = ledger.records[prepared.logicalID]
        guard previousRecord == prepared.expectedPreviousRecord else {
            throw BrowserWebExtensionInstallError.installPreviewExpired
        }
        let currentSourceRecord: BrowserWebExtensionManagedRecord?
        switch prepared.source {
        case .package(_, let catalogID, _):
            if let catalogID {
                currentSourceRecord = try uniqueManagedRecord(in: ledger) { record in
                    guard case .catalogArchive(_, _, let installedCatalogID) = record.source else {
                        return false
                    }
                    return installedCatalogID == catalogID
                }
            } else if let expectedPackageDigest = prepared.expectedPackageDigest {
                currentSourceRecord = try uniqueManagedRecord(in: ledger) { record in
                    guard case .directory(_, let installedDigest) = record.source else {
                        return false
                    }
                    return installedDigest.caseInsensitiveCompare(expectedPackageDigest) == .orderedSame
                }
            } else {
                currentSourceRecord = nil
            }
        case .safariApp(let reference):
            currentSourceRecord = try uniqueManagedRecord(in: ledger) { record in
                guard case .safariApp(let installedReference) = record.source else {
                    return false
                }
                return installedReference.bundleIdentifier == reference.bundleIdentifier
            }
        }
        guard currentSourceRecord == prepared.expectedPreviousRecord else {
            throw BrowserWebExtensionInstallError.installPreviewExpired
        }
        let previousContext = previousRecord.flatMap { record in
            loadedContexts.first { managedRecordIDsByContextIdentifier[$0.uniqueIdentifier] == record.id }
        }
        let requiredPermissions = Set(prepared.preview.requiredPermissions)
        let requiredHosts = Set(prepared.preview.requiredHosts)
        let allowedOptionalPermissions = grantedOptionalPermissions.intersection(
            prepared.preview.optionalPermissions
        )
        let allowedOptionalHosts = grantedOptionalHosts.intersection(prepared.preview.optionalHosts)
        var installedPackage: BrowserWebExtensionInstalledPackage?
        let record: BrowserWebExtensionManagedRecord
        let reviewedWebExtension: WKWebExtension
        let installationName: String
        var safariReference: BrowserWebExtensionAppExtensionReference?
        var attemptedContextIdentifier: String?
        var committedRecord: BrowserWebExtensionManagedRecord?
        var committedReceipt: BrowserWebExtensionInstallReceipt?
        do {
            switch prepared.source {
            case .package(let sourceURL, let catalogID, _):
                let installed = try await directoryRepository.installImmutableCandidate(
                    from: sourceURL,
                    into: directory
                )
                installedPackage = installed
                guard installed.digest == prepared.expectedPackageDigest else {
                    throw BrowserWebExtensionInstallError.integrityMismatch
                }
                reviewedWebExtension = try await WKWebExtension(resourceBaseURL: installed.url)
                try requireActive()
                try validateReviewedManifest(reviewedWebExtension, against: prepared.preview)
                installationName = installed.url.lastPathComponent
                let managedSource: BrowserWebExtensionManagedSource = if let catalogID {
                    .catalogArchive(
                        filename: installed.url.lastPathComponent,
                        digest: installed.digest,
                        catalogID: catalogID
                    )
                } else {
                    .directory(filename: installed.url.lastPathComponent, digest: installed.digest)
                }
                record = BrowserWebExtensionManagedRecord(
                    id: prepared.logicalID,
                    displayName: prepared.preview.name,
                    version: prepared.preview.version,
                    source: managedSource,
                    isEnabled: previousRecord?.isEnabled ?? true,
                    isToolbarPinned: previousRecord?.isToolbarPinned ?? false,
                    webExtensionContextIdentifier: previousRecord.map {
                        Self.contextIdentifier(for: $0)
                    } ?? Self.freshContextIdentifier(),
                    grantedPermissions: Array(requiredPermissions.union(allowedOptionalPermissions)),
                    requiredPermissions: Array(requiredPermissions),
                    deniedPermissions: [],
                    grantedMatchPatterns: Array(requiredHosts.union(allowedOptionalHosts)),
                    requiredMatchPatterns: Array(requiredHosts),
                    deniedMatchPatterns: [],
                    capabilityNotices: prepared.preview.capabilityNotices
                )
            case .safariApp(let reference):
                _ = try await verifySafariAppExtension(reference.bundleURL)
                try requireActive()
                reviewedWebExtension = try await webExtension(for: reference)
                try requireActive()
                try validateReviewedManifest(reviewedWebExtension, against: prepared.preview)
                installationName = reference.installationName
                safariReference = reference
                record = BrowserWebExtensionManagedRecord(
                    id: prepared.logicalID,
                    displayName: prepared.preview.name,
                    version: prepared.preview.version,
                    source: .safariApp(reference),
                    isEnabled: previousRecord?.isEnabled ?? true,
                    isToolbarPinned: previousRecord?.isToolbarPinned ?? false,
                    webExtensionContextIdentifier: previousRecord.map {
                        Self.contextIdentifier(for: $0)
                    } ?? Self.freshContextIdentifier(),
                    grantedPermissions: Array(requiredPermissions.union(allowedOptionalPermissions)),
                    requiredPermissions: Array(requiredPermissions),
                    deniedPermissions: [],
                    grantedMatchPatterns: Array(requiredHosts.union(allowedOptionalHosts)),
                    requiredMatchPatterns: Array(requiredHosts),
                    deniedMatchPatterns: [],
                    capabilityNotices: prepared.preview.capabilityNotices
                )
            }
            attemptedContextIdentifier = Self.contextIdentifier(for: record)
            if let previousContext {
                cancelPermissionPrompts(for: previousContext)
                await closePresentedPopups(
                    forExtensionIdentifier: previousContext.uniqueIdentifier
                )
                try unloadContext(previousContext)
                loadedContexts.removeAll { $0 === previousContext }
                managedRecordIDsByContextIdentifier.removeValue(forKey: previousContext.uniqueIdentifier)
                clearTransientState(
                    forExtensionIdentifier: previousContext.uniqueIdentifier
                )
            }
            // Safari apps can update while the review sheet is open. Verify the
            // exact app and appex identity again immediately before controller
            // loading. Verification suspends off-main so the UI and load
            // deadline remain responsive.
            if let safariReference {
                _ = try await verifySafariAppExtension(safariReference.bundleURL)
                try requireActive()
            }
            let context: WKWebExtensionContext?
            if record.isEnabled {
                context = try loadExtension(
                    reviewedWebExtension,
                    installationName: installationName,
                    supportsNativeMessaging: safariReference != nil,
                    managedRecord: record
                )
                try requireActive()
            } else {
                context = nil
            }
            // The package is immutable and the new context is healthy. The
            // atomic ledger write is now the only commit point.
            guard try await directoryRepository.replaceManagedRecord(
                record,
                expectedPreviousRecord: previousRecord,
                in: directory
            ) else {
                throw BrowserWebExtensionInstallError.installPreviewExpired
            }
            committedRecord = record
            let receipt = BrowserWebExtensionInstallReceipt(
                name: context?.webExtension.displayName
                    ?? reviewedWebExtension.displayName
                    ?? record.displayName
            )
            committedReceipt = receipt
            try await postManagementCommitHook()
            managedRecords[record.id] = record
            let contextIdentifier = Self.contextIdentifier(for: record)
            if record.isEnabled, record.isToolbarPinned {
                toolbarPinnedExtensionIdentifiers.insert(contextIdentifier)
            } else {
                toolbarPinnedExtensionIdentifiers.remove(contextIdentifier)
            }
            if let previousRecord,
               let previousPackageURL = managedPackageURL(for: previousRecord),
               previousPackageURL != installedPackage?.url {
                try? await directoryRepository.removeManagedPackageIfUnreferenced(
                    at: previousPackageURL,
                    in: directory
                )
            }
            profileRuntime.invalidateSnapshot()
            return receipt
        } catch {
            // A successful atomic ledger replacement is irreversible for this
            // operation. Cancellation observed after that point must not put
            // memory and the live controller back on the previous record.
            if let committedRecord, let committedReceipt {
                managedRecords[committedRecord.id] = committedRecord
                let identifier = Self.contextIdentifier(for: committedRecord)
                if committedRecord.isEnabled, committedRecord.isToolbarPinned {
                    toolbarPinnedExtensionIdentifiers.insert(identifier)
                } else {
                    toolbarPinnedExtensionIdentifiers.remove(identifier)
                }
                profileRuntime.invalidateSnapshot()
                if error is CancellationError {
                    return committedReceipt
                }
                throw error
            }
            if let attemptedContextIdentifier,
               let newContext = loadedContexts.first(where: {
                   $0.uniqueIdentifier == attemptedContextIdentifier
               }) {
                cancelPermissionPrompts(for: newContext)
                _ = try? unloadContext(newContext)
                loadedContexts.removeAll { $0 === newContext }
                managedRecordIDsByContextIdentifier.removeValue(forKey: attemptedContextIdentifier)
            }
            if let authoritativeLedger = try? await directoryRepository
                .managementLedger(in: directory),
               let authoritativeRecord = authoritativeLedger.records[prepared.logicalID],
               authoritativeRecord.isEnabled {
                _ = try? await loadManagedRecord(authoritativeRecord)
            }
            if let installedPackage {
                try? await directoryRepository.removeManagedPackageIfUnreferenced(
                    at: installedPackage.url,
                    in: directory
                )
            }
            throw error
        }
    }

    private func validateReviewedManifest(
        _ webExtension: WKWebExtension,
        against preview: BrowserWebExtensionInstallPreview
    ) throws {
        try validateLoadableManifest(webExtension)
        let optionalPatterns = webExtension.optionalPermissionMatchPatterns
        let requiredPatterns = webExtension.allRequestedMatchPatterns
            .union(webExtension.requestedPermissionMatchPatterns)
            .subtracting(optionalPatterns)
        guard (webExtension.displayName ?? preview.name) == preview.name,
              (webExtension.version ?? "") == preview.version,
              Set(webExtension.requestedPermissions.map(\.rawValue)) == Set(preview.requiredPermissions),
              Set(requiredPatterns.map(\.string)) == Set(preview.requiredHosts),
              Set(webExtension.optionalPermissions.map(\.rawValue)) == Set(preview.optionalPermissions),
              Set(optionalPatterns.map(\.string)) == Set(preview.optionalHosts) else {
            throw BrowserWebExtensionInstallError.integrityMismatch
        }
    }

    private func validateLoadableManifest(_ webExtension: WKWebExtension) throws {
        let displayName = webExtension.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let version = webExtension.version?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !Self.hasFatalManifestError(webExtension.errors),
              !webExtension.manifest.isEmpty,
              webExtension.manifestVersion > 0,
              !displayName.isEmpty,
              !version.isEmpty else {
            throw BrowserWebExtensionApprovalValidationError(
                message: String(
                    localized: "browser.extensions.load.failed",
                    defaultValue: "The extension could not be loaded."
                )
            )
        }
    }

    nonisolated static func hasFatalManifestError(_ errors: [any Error]) -> Bool {
        errors.contains { error in
            let error = error as NSError
            guard error.domain == WKWebExtension.errorDomain else { return true }
            switch error.code {
            case WKWebExtension.Error.resourceNotFound.rawValue,
                 WKWebExtension.Error.invalidManifestEntry.rawValue,
                 WKWebExtension.Error.invalidDeclarativeNetRequestEntry.rawValue,
                 WKWebExtension.Error.invalidBackgroundPersistence.rawValue:
                // WebKit reports recoverable entry errors while still producing
                // a usable extension. Safari also loads these extensions with
                // the affected entry omitted or normalized.
                return false
            case WKWebExtension.Error.unknown.rawValue,
                 WKWebExtension.Error.invalidResourceCodeSignature.rawValue,
                 WKWebExtension.Error.invalidManifest.rawValue,
                 WKWebExtension.Error.unsupportedManifestVersion.rawValue,
                 WKWebExtension.Error.invalidArchive.rawValue:
                return true
            default:
                return true
            }
        }
    }

#if DEBUG
    func approveInstalledCandidate(_ candidate: URL) async throws {
        try requireActive()
        let digest = try await directoryRepository.digestForManagedPackage(at: candidate)
        try requireActive()
        let webExtension = try await WKWebExtension(resourceBaseURL: candidate)
        try requireActive()
        let optionalPatterns = webExtension.optionalPermissionMatchPatterns
        let requiredPatterns = webExtension.allRequestedMatchPatterns
            .union(webExtension.requestedPermissionMatchPatterns)
            .subtracting(optionalPatterns)
        let record = BrowserWebExtensionManagedRecord(
            id: candidate.lastPathComponent,
            displayName: webExtension.displayName ?? candidate.deletingPathExtension().lastPathComponent,
            version: webExtension.version ?? "",
            source: .directory(filename: candidate.lastPathComponent, digest: digest),
            isEnabled: true,
            grantedPermissions: webExtension.requestedPermissions.map(\.rawValue),
            requiredPermissions: webExtension.requestedPermissions.map(\.rawValue),
            deniedPermissions: [],
            grantedMatchPatterns: requiredPatterns.map(\.string),
            requiredMatchPatterns: requiredPatterns.map(\.string),
            deniedMatchPatterns: []
        )
        try await directoryRepository.upsertManagedRecord(record, in: directory)
    }
#endif

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
        guard let recordID = managedRecordIDsByContextIdentifier[uniqueIdentifier],
              var record = managedRecords[recordID] else {
            publishActionFailure(
                .toolbarPinFailed,
                context: context,
                panelID: nil
            )
            throw BrowserWebExtensionToolbarPinError.actionUnavailable
        }
        let previousRecord = record
        record.isToolbarPinned = isPinned
        do {
            guard try await directoryRepository.replaceManagedRecord(
                record,
                expectedPreviousRecord: previousRecord,
                in: directory
            ) else {
                throw BrowserWebExtensionManagementError.stateChanged
            }
        } catch {
            publishActionFailure(
                .toolbarPinFailed,
                context: context,
                panelID: nil
            )
            throw error
        }
        actionFailures.removeValue(forKey: ActionUpdateKey(
            extensionIdentifier: uniqueIdentifier,
            panelID: nil
        ))
        managedRecords[recordID] = record
        if isPinned {
            toolbarPinnedExtensionIdentifiers.insert(uniqueIdentifier)
        } else {
            toolbarPinnedExtensionIdentifiers.remove(uniqueIdentifier)
        }
        profileRuntime.publishActionUpdate(
            BrowserWebExtensionActionUpdate(
                profileID: profileRuntime.profileID,
                panelID: nil,
                item: presentationItem(for: context, action: nil, panelID: nil)
            )
        )
    }

    func setExtensionEnabled(
        managementID: String,
        isEnabled: Bool
    ) async throws {
        try requireActive()
        guard var record = managedRecords[managementID] else {
            throw BrowserWebExtensionManagementError.extensionNotFound
        }
        let previousRecord = record
        guard record.isEnabled != isEnabled
            || (isEnabled && failedManagedRecordIDs.contains(managementID)) else { return }
        let context = loadedContext(managementID: managementID)
        if isEnabled {
            let newContext = try await loadManagedRecord(record)
            record.isEnabled = true
            do {
                guard try await directoryRepository.replaceManagedRecord(
                    record,
                    expectedPreviousRecord: previousRecord,
                    in: directory
                ) else {
                    throw BrowserWebExtensionManagementError.stateChanged
                }
            } catch {
                _ = try? unloadContext(newContext)
                loadedContexts.removeAll { $0 === newContext }
                managedRecordIDsByContextIdentifier.removeValue(forKey: newContext.uniqueIdentifier)
                await restoreAuthoritativeManagedRecord(managementID: managementID)
                throw error
            }
            managedRecords[managementID] = record
            if record.isToolbarPinned {
                toolbarPinnedExtensionIdentifiers.insert(newContext.uniqueIdentifier)
            } else {
                toolbarPinnedExtensionIdentifiers.remove(newContext.uniqueIdentifier)
            }
            clearManagedLoadFailure(for: record)
        } else {
            if let context {
                cancelPermissionPrompts(for: context)
                await closePresentedPopups(
                    forExtensionIdentifier: context.uniqueIdentifier
                )
                try unloadContext(context)
                loadedContexts.removeAll { $0 === context }
                managedRecordIDsByContextIdentifier.removeValue(forKey: context.uniqueIdentifier)
            }
            record.isEnabled = false
            do {
                guard try await directoryRepository.replaceManagedRecord(
                    record,
                    expectedPreviousRecord: previousRecord,
                    in: directory
                ) else {
                    throw BrowserWebExtensionManagementError.stateChanged
                }
            } catch {
                await restoreAuthoritativeManagedRecord(managementID: managementID)
                throw error
            }
            managedRecords[managementID] = record
            clearManagedLoadFailure(for: record)
            let identifier = Self.contextIdentifier(for: record)
            toolbarPinnedExtensionIdentifiers.remove(identifier)
            clearTransientState(
                forExtensionIdentifier: identifier
            )
        }
        profileRuntime.invalidateSnapshot()
    }

    func removeExtension(managementID: String) async throws {
        try requireActive()
        guard let record = managedRecords[managementID] else {
            throw BrowserWebExtensionManagementError.extensionNotFound
        }
        let identifier = Self.contextIdentifier(for: record)
        if let context = loadedContext(managementID: managementID) {
            cancelPermissionPrompts(for: context)
            await closePresentedPopups(forExtensionIdentifier: context.uniqueIdentifier)
            try unloadContext(context)
            loadedContexts.removeAll { $0 === context }
            managedRecordIDsByContextIdentifier.removeValue(forKey: context.uniqueIdentifier)
        }
        try requireActive()
        do {
            guard try await directoryRepository.removeManagedRecord(
                id: managementID,
                expectedPreviousRecord: record,
                in: directory
            ) else {
                throw BrowserWebExtensionManagementError.stateChanged
            }
        } catch {
            await restoreAuthoritativeManagedRecord(managementID: managementID)
            throw error
        }
        managedRecords.removeValue(forKey: managementID)
        toolbarPinnedExtensionIdentifiers.remove(identifier)
        clearTransientState(forExtensionIdentifier: identifier)
        // WKWebExtensionController unloads contexts synchronously while its
        // storage queues close asynchronously. Eager data deletion can unlink
        // an open SQLite WAL. Keep the now-unreachable record quarantined;
        // the next controller startup removes it before loading any context.
        if let packageURL = managedPackageURL(for: record) {
            try? await directoryRepository.removeManagedPackageIfUnreferenced(
                at: packageURL,
                in: directory
            )
        }
        profileRuntime.invalidateSnapshot()
    }

    func revokeOptionalPermissions(managementID: String) async throws {
        try requireActive()
        guard var record = managedRecords[managementID] else {
            throw BrowserWebExtensionManagementError.extensionNotFound
        }
        let previousRecord = record
        let expiration = Date.distantFuture
        record.grantedPermissions = Dictionary(uniqueKeysWithValues: record.requiredPermissions.map {
            ($0, expiration)
        })
        record.deniedPermissions = [:]
        record.grantedMatchPatterns = Dictionary(uniqueKeysWithValues: record.requiredMatchPatterns.map {
            ($0, expiration)
        })
        record.deniedMatchPatterns = [:]
        record.hasRequestedOptionalAccessToAllHosts = false
        guard try await directoryRepository.replaceManagedRecord(
            record,
            expectedPreviousRecord: previousRecord,
            in: directory
        ) else {
            throw BrowserWebExtensionManagementError.stateChanged
        }
        managedRecords[managementID] = record
        if let context = loadedContext(managementID: managementID) {
            applyPersistedPermissions(in: context, record: record)
        }
        profileRuntime.invalidateSnapshot()
    }

    private func restoreAuthoritativeManagedRecord(managementID: String) async {
        let previousRecord = managedRecords[managementID]
        guard let ledger = try? await directoryRepository.managementLedger(in: directory),
              let record = ledger.records[managementID] else {
            managedRecords.removeValue(forKey: managementID)
            if let previousRecord {
                toolbarPinnedExtensionIdentifiers.remove(Self.contextIdentifier(for: previousRecord))
            }
            return
        }
        managedRecords[managementID] = record
        let identifier = Self.contextIdentifier(for: record)
        if record.isEnabled, record.isToolbarPinned {
            toolbarPinnedExtensionIdentifiers.insert(identifier)
        } else {
            toolbarPinnedExtensionIdentifiers.remove(identifier)
        }
        guard record.isEnabled, loadedContext(managementID: managementID) == nil else { return }
        _ = try? await loadManagedRecord(record)
    }

    func prepareUpdate(managementID: String) async throws -> BrowserWebExtensionInstallPreview {
        guard let record = managedRecords[managementID] else {
            throw BrowserWebExtensionManagementError.extensionNotFound
        }
        switch record.source {
        case .catalogArchive(_, _, let catalogID):
            guard let entry = BrowserWebExtensionCatalog.production.entry(id: catalogID) else {
                throw BrowserWebExtensionManagementError.updateUnavailable
            }
            guard Self.trustedUpdateAvailable(
                for: record,
                loadedVersion: loadedContext(managementID: managementID)?.webExtension.version
            ) == true else {
                throw BrowserWebExtensionManagementError.upToDate
            }
            return try await prepareCatalogInstall(entry)
        case .safariApp(let reference):
            _ = try await verifySafariAppExtension(reference.bundleURL)
            try requireActive()
            let candidate = try await webExtension(for: reference)
            guard candidate.version != record.version else {
                throw BrowserWebExtensionManagementError.upToDate
            }
            return try await prepareInstall(from: reference.bundleURL)
        case .directory:
            throw BrowserWebExtensionManagementError.updateUnavailable
        }
    }

    private func loadedContext(managementID: String) -> WKWebExtensionContext? {
        loadedContexts.first {
            managedRecordIDsByContextIdentifier[$0.uniqueIdentifier] == managementID
        }
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
        createTab: @escaping @MainActor (Int, Bool, Bool) -> BrowserPanel? = { _, _, _ in nil },
        closePanel: @escaping @MainActor (UUID) -> Bool = { _ in false },
        isPanelPinned: @escaping @MainActor (UUID) -> Bool = { _ in false },
        setPanelPinned: @escaping @MainActor (UUID, Bool) -> Bool = { _, _ in false }
    ) {
        if let existingTabAdapter = tabAdapters[panel.id] {
            pendingPanelUnregistrations.remove(panel.id)
            guard existingTabAdapter.windowAdapter?.ownerID != ownerID else { return }

            let oldWindowAdapter = existingTabAdapter.windowAdapter
            let oldIndex = oldWindowAdapter?.compactTabs().firstIndex {
                $0 === existingTabAdapter
            } ?? NSNotFound
            let wasReportedVisible = oldWindowAdapter?
                .lastReportedVisiblePanelIDs.contains(panel.id) == true
            oldWindowAdapter?.tabAdapters.removeAll {
                $0 === existingTabAdapter || $0.panel == nil
            }

            let newWindowAdapter = windowAdapters[ownerID] ?? makeWindowAdapter(
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
            existingTabAdapter.windowAdapter = newWindowAdapter
            newWindowAdapter.tabAdapters.append(existingTabAdapter)
            if wasReportedVisible {
                controller.didMoveTab(
                    existingTabAdapter,
                    from: oldIndex,
                    in: oldWindowAdapter
                )
            }
            oldWindowAdapter?.lastReportedVisiblePanelIDs = oldWindowAdapter?
                .compactTabs().compactMap { $0.panel?.id } ?? []
            newWindowAdapter.lastReportedVisiblePanelIDs = newWindowAdapter
                .compactTabs().compactMap { $0.panel?.id }
            if let oldWindowAdapter, oldWindowAdapter.tabAdapters.isEmpty {
                windowAdapters.removeValue(forKey: oldWindowAdapter.ownerID)
                controller.didCloseWindow(oldWindowAdapter)
            }
            return
        }

        let windowAdapter = windowAdapters[ownerID] ?? makeWindowAdapter(
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

        let tabAdapter = BrowserWebExtensionTabAdapter(panel: panel, windowAdapter: windowAdapter)
        tabAdapters[panel.id] = tabAdapter
        windowAdapter.tabAdapters.append(tabAdapter)
        if panel.internalPage == nil {
#if DEBUG
            debugDidOpenTabEventCount += 1
#endif
            controller.didOpenTab(tabAdapter)
        }
        windowAdapter.lastReportedVisiblePanelIDs = windowAdapter.compactTabs().compactMap { $0.panel?.id }
    }

    private func makeWindowAdapter(
        ownerID: UUID,
        activePanelID: @escaping @MainActor () -> UUID?,
        focusPriority: @escaping @MainActor () -> Int,
        focusPanel: @escaping @MainActor (UUID) -> Void,
        orderedPanelIDs: @escaping @MainActor () -> [UUID],
        createTab: @escaping @MainActor (Int, Bool, Bool) -> BrowserPanel?,
        closePanel: @escaping @MainActor (UUID) -> Bool,
        isPanelPinned: @escaping @MainActor (UUID) -> Bool,
        setPanelPinned: @escaping @MainActor (UUID, Bool) -> Bool
    ) -> BrowserWebExtensionWindowAdapter {
        let windowAdapter = BrowserWebExtensionWindowAdapter(
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
        windowAdapters[ownerID] = windowAdapter
        controller.didOpenWindow(windowAdapter)
        return windowAdapter
    }

    func unregister(panelID: UUID) {
        guard tabAdapters[panelID] != nil else {
            clearTransientState(forPanelID: panelID)
            return
        }
        pendingPanelUnregistrations.insert(panelID)
        clearTransientState(forPanelID: panelID)
        finalizePanelUnregistrationIfPossible(panelID)
    }

    func registerPopupWindow(
        _ popup: BrowserPopupWindowController,
        openerPanelID: UUID?,
        parentPopupWindowID: UUID?
    ) {
        guard !isShutDown, popupWindowAdapters[popup.webExtensionWindowID] == nil else { return }
        let windowAdapter = BrowserWebExtensionPopupWindowAdapter(
            ownerID: popup.webExtensionWindowID,
            popupController: popup
        )
        let tabAdapter = BrowserWebExtensionPopupTabAdapter(
            popupController: popup,
            windowAdapter: windowAdapter,
            duplicateTab: { [weak self, weak popup] configuration in
                guard let self,
                      let windowAdapter = openerPanelID
                        .flatMap({ self.tabAdapters[$0]?.windowAdapter })
                        ?? self.focusedWindowAdapter()
                        ?? self.orderedWindowAdapters().first else {
                    throw BrowserWebExtensionNewTabError.creationFailed
                }
                return try self.openExtensionTab(
                    in: windowAdapter,
                    index: configuration.index,
                    shouldBeActive: configuration.shouldBeActive,
                    shouldAddToSelection: configuration.shouldAddToSelection,
                    url: configuration.url ?? popup?.webView.url,
                    parentTab: configuration.parentTab,
                    shouldBePinned: configuration.shouldBePinned,
                    shouldBeMuted: configuration.shouldBeMuted,
                    shouldReaderModeBeActive: configuration.shouldReaderModeBeActive
                )
            }
        )
        if let parentPopupWindowID,
           let parent = popupWindowAdapters[parentPopupWindowID]?.tabAdapter {
            tabAdapter.parentTabObject = parent
        } else if let openerPanelID,
                  let opener = tabAdapters[openerPanelID] {
            tabAdapter.parentTabObject = opener
        }
        windowAdapter.tabAdapter = tabAdapter
        popupWindowAdapters[popup.webExtensionWindowID] = windowAdapter
        controller.didOpenWindow(windowAdapter)
#if DEBUG
        debugDidOpenTabEventCount += 1
#endif
        controller.didOpenTab(tabAdapter)
    }

    func unregisterPopupWindow(id: UUID) {
        guard let windowAdapter = popupWindowAdapters.removeValue(forKey: id) else { return }
        if let tabAdapter = windowAdapter.tabAdapter {
#if DEBUG
            debugDidCloseTabEventCount += 1
#endif
            controller.didCloseTab(tabAdapter, windowIsClosing: true)
        }
        controller.didCloseWindow(windowAdapter)
        windowAdapter.tabAdapter = nil
    }

    private func finalizePanelUnregistrationIfPossible(_ panelID: UUID) {
        guard pendingPanelUnregistrations.contains(panelID),
              !presentedPopups.values.contains(where: { $0.panelID == panelID }) else {
            return
        }
        pendingPanelUnregistrations.remove(panelID)
        guard let tabAdapter = tabAdapters.removeValue(forKey: panelID) else { return }
        guard let windowAdapter = tabAdapter.windowAdapter else { return }
        if windowAdapter.lastReportedVisiblePanelIDs.contains(panelID) {
#if DEBUG
            debugDidCloseTabEventCount += 1
#endif
            controller.didCloseTab(tabAdapter, windowIsClosing: false)
        }
        windowAdapter.tabAdapters.removeAll { $0 === tabAdapter || $0.panel == nil }
        windowAdapter.lastReportedVisiblePanelIDs = windowAdapter.compactTabs().compactMap { $0.panel?.id }
        if windowAdapter.tabAdapters.isEmpty {
            windowAdapters.removeValue(forKey: windowAdapter.ownerID)
            controller.didCloseWindow(windowAdapter)
        }
    }

    private func clearTransientState(forPanelID panelID: UUID) {
        let invocationKeys = Set(
            pendingActionInvocations.keys.filter { $0.panelID == panelID }
                + lastActionInvocations.keys.filter { $0.panelID == panelID }
                + popupHandoffDeadlineTasks.keys.filter { $0.panelID == panelID }
                + actionsAwaitingReadyPopup.filter { $0.panelID == panelID }
                + expiredPopupHandoffs.filter { $0.panelID == panelID }
                + dismissedPopupKeys.filter { $0.panelID == panelID }
                + popupClosuresRequestedByActionButton.filter { $0.panelID == panelID }
        )
        let popoverEntries = presentedPopups.values.filter { $0.panelID == panelID }
        let extensionIdentifiers = Set(
            invocationKeys.map(\.extensionIdentifier)
                + popoverEntries.map(\.extensionIdentifier)
        )
        for key in invocationKeys {
            popupHandoffDeadlineTasks.removeValue(forKey: key)?.cancel()
            pendingActionInvocations.removeValue(forKey: key)
            lastActionInvocations.removeValue(forKey: key)
            actionsAwaitingReadyPopup.remove(key)
            expiredPopupHandoffs.remove(key)
            dismissedPopupKeys.remove(key)
            popupClosuresRequestedByActionButton.remove(key)
        }
        for popup in popoverEntries {
            popup.requestLifecycleClose()
        }
#if DEBUG
        debugSyntheticPopupKeys = debugSyntheticPopupKeys.filter { $0.value.panelID != panelID }
#endif
        for identifier in extensionIdentifiers {
            popupWebViews.removeValue(forKey: identifier)
        }
        pendingActionUpdates = pendingActionUpdates.filter { $0.key.panelID != panelID }
        presentationIconCache = presentationIconCache.filter { $0.key.panelID != panelID }
        actionFailures = actionFailures.filter { $0.key.panelID != panelID }
    }

    private func clearTransientState(forExtensionIdentifier identifier: String) {
        let invocationKeys = Set(
            pendingActionInvocations.keys.filter { $0.extensionIdentifier == identifier }
                + lastActionInvocations.keys.filter { $0.extensionIdentifier == identifier }
                + popupHandoffDeadlineTasks.keys.filter { $0.extensionIdentifier == identifier }
                + actionsAwaitingReadyPopup.filter { $0.extensionIdentifier == identifier }
                + expiredPopupHandoffs.filter { $0.extensionIdentifier == identifier }
                + dismissedPopupKeys.filter { $0.extensionIdentifier == identifier }
                + popupClosuresRequestedByActionButton.filter { $0.extensionIdentifier == identifier }
        )
        for key in invocationKeys {
            popupHandoffDeadlineTasks.removeValue(forKey: key)?.cancel()
            pendingActionInvocations.removeValue(forKey: key)
            lastActionInvocations.removeValue(forKey: key)
            actionsAwaitingReadyPopup.remove(key)
            expiredPopupHandoffs.remove(key)
            dismissedPopupKeys.remove(key)
            popupClosuresRequestedByActionButton.remove(key)
        }
        for popup in presentedPopups.values where popup.extensionIdentifier == identifier {
            popup.requestLifecycleClose()
        }
#if DEBUG
        debugSyntheticPopupKeys = debugSyntheticPopupKeys.filter {
            $0.value.extensionIdentifier != identifier
        }
#endif
        popupWebViews.removeValue(forKey: identifier)
        pendingActionUpdates = pendingActionUpdates.filter {
            $0.key.extensionIdentifier != identifier
        }
        presentationIconCache = presentationIconCache.filter {
            $0.key.extensionIdentifier != identifier
        }
        actionFailures = actionFailures.filter {
            $0.key.extensionIdentifier != identifier
        }
    }

    private func closePresentedPopups(forExtensionIdentifier identifier: String) async {
        let matchingPopups = presentedPopups.values.filter {
            $0.extensionIdentifier == identifier
        }
        guard !matchingPopups.isEmpty else { return }
        for popup in matchingPopups {
            popup.requestLifecycleClose()
        }
        guard presentedPopups.values.contains(where: {
            $0.extensionIdentifier == identifier
        }) else { return }
        await withCheckedContinuation { continuation in
            if presentedPopups.values.contains(where: {
                $0.extensionIdentifier == identifier
            }) {
                popupQuiescenceWaiters[identifier, default: []].append(continuation)
            } else {
                continuation.resume()
            }
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
        createTab: @MainActor (Int, Bool, Bool) -> BrowserPanel?,
        closePanel: @MainActor (UUID) -> Bool,
        isPanelPinned: @MainActor (UUID) -> Bool,
        setPanelPinned: @MainActor (UUID, Bool) -> Bool
    )? {
        guard let windowAdapter = tabAdapters[panelID]?.windowAdapter else { return nil }
        return (
            windowAdapter.ownerID,
            windowAdapter.activePanelID,
            windowAdapter.focusPriority,
            windowAdapter.focusPanel,
            windowAdapter.orderedPanelIDs,
            windowAdapter.createTab,
            windowAdapter.closePanel,
            windowAdapter.isPanelPinned,
            windowAdapter.setPanelPinned
        )
    }

    func tabVisibilityDidChange(panelID: UUID) {
        guard let tabAdapter = tabAdapters[panelID],
              let windowAdapter = tabAdapter.windowAdapter else { return }
        let wasVisible = windowAdapter.lastReportedVisiblePanelIDs.contains(panelID)
        let isVisible = tabAdapter.panel?.internalPage == nil
        guard wasVisible != isVisible else { return }

        if isVisible {
#if DEBUG
            debugDidOpenTabEventCount += 1
#endif
            controller.didOpenTab(tabAdapter)
        } else {
            controller.didDeselectTabs([tabAdapter])
#if DEBUG
            debugDidCloseTabEventCount += 1
#endif
            controller.didCloseTab(tabAdapter, windowIsClosing: false)
        }
        windowAdapter.lastReportedVisiblePanelIDs = windowAdapter.compactTabs().compactMap { $0.panel?.id }
    }

    nonisolated static func movedPanelIDForSingleMove(
        previous: [UUID],
        current: [UUID]
    ) -> UUID? {
        guard previous.count == current.count,
              previous != current,
              Set(previous) == Set(current) else {
            return nil
        }
        let currentIndices = Dictionary(
            uniqueKeysWithValues: current.enumerated().map { ($0.element, $0.offset) }
        )
        let candidates = previous.enumerated().compactMap { oldIndex, panelID -> (UUID, Int)? in
            guard let newIndex = currentIndices[panelID], oldIndex != newIndex else { return nil }
            var simulated = previous
            simulated.remove(at: oldIndex)
            simulated.insert(panelID, at: newIndex)
            guard simulated == current else { return nil }
            return (panelID, abs(newIndex - oldIndex))
        }
        return candidates.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.uuidString < rhs.0.uuidString
        }.first?.0
    }

    func synchronizeTabOrder(ownerID: UUID, movedPanelID: UUID? = nil) {
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
        let resolvedMovedPanelID = movedPanelID.flatMap { panelID in
            previousIndices[panelID] != nil && current.contains(panelID) ? panelID : nil
        } ?? Self.movedPanelIDForSingleMove(previous: previous, current: current)
        if let panelID = resolvedMovedPanelID,
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
        guard let context = loadedContexts.first(where: { $0.uniqueIdentifier == uniqueIdentifier }) else {
            return false
        }
        guard let tabAdapter = tabAdapters[panel.id],
              let action = context.action(for: tabAdapter) else {
            publishActionFailure(.actionUnavailable, context: context, panelID: panel.id)
            return false
        }
        guard action.isEnabled else { return false }
        let key = ActionInvocationKey(
            extensionIdentifier: context.uniqueIdentifier,
            panelID: panel.id
        )
        actionFailures.removeValue(forKey: ActionUpdateKey(
            extensionIdentifier: context.uniqueIdentifier,
            panelID: panel.id
        ))
        if dismissedPopupKeys.remove(key) != nil {
            cancelPopupHandoff(for: key)
            return true
        }
        if let popover = action.popupPopover, popover.isShown {
            popupClosuresRequestedByActionButton.insert(key)
            popover.performClose(nil)
            cancelPopupHandoff(for: key)
            return true
        }
        expiredPopupHandoffs.remove(key)
        let invocation = PendingActionInvocation(
            anchorView: anchorView,
            panelID: panel.id
        )
        cancelPopupHandoff(for: key)
        pendingActionInvocations[key] = [invocation]
        lastActionInvocations[key] = invocation
        enqueueActionUpdate(action: action, context: context, panelID: panel.id)
        if action.presentsPopup {
            actionsAwaitingReadyPopup.insert(key)
            performExtensionAction(context, tabAdapter)
            schedulePopupHandoffDeadline(for: key, invocationID: invocation.id)
            return true
        }
        // Some MV2 extensions install a popup only after handling the click.
        // Retain the anchor until `didUpdate` observes that transition.
        performExtensionAction(context, tabAdapter)
        schedulePopupHandoffDeadline(for: key, invocationID: invocation.id)
        return true
    }

    private func schedulePopupHandoffDeadline(
        for key: ActionInvocationKey,
        invocationID: UUID
    ) {
        let waitForDeadline = waitForPopupHandoffDeadline
        popupHandoffDeadlineTasks[key] = Task { @MainActor [weak self] in
            do {
                try await waitForDeadline()
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.pendingActionInvocations[key]?.first?.id == invocationID else {
                return
            }
            self.expirePopupHandoff(for: key)
        }
    }

    private func cancelPopupHandoff(for key: ActionInvocationKey) {
        popupHandoffDeadlineTasks.removeValue(forKey: key)?.cancel()
        actionsAwaitingReadyPopup.remove(key)
        let cancelledInvocationID = pendingActionInvocations.removeValue(forKey: key)?.first?.id
        if lastActionInvocations[key]?.id == cancelledInvocationID {
            lastActionInvocations.removeValue(forKey: key)
        }
        refreshActionPresentation(for: key)
    }

    private func expirePopupHandoff(for key: ActionInvocationKey) {
        // A click-only action is complete once its listener runs. Only actions
        // that declared a popup can time out and surface a retry state.
        if actionsAwaitingReadyPopup.contains(key) {
            expiredPopupHandoffs.insert(key)
        }
        cancelPopupHandoff(for: key)
    }

    private func refreshActionPresentation(for key: ActionInvocationKey) {
        guard let context = loadedContexts.first(where: {
            $0.uniqueIdentifier == key.extensionIdentifier
        }) else { return }
        let action = tabAdapters[key.panelID].flatMap { context.action(for: $0) }
        enqueueActionUpdate(action: action, context: context, panelID: key.panelID)
    }

    private func publishActionFailure(
        _ failure: BrowserWebExtensionActionFailure,
        context: WKWebExtensionContext,
        panelID: UUID?
    ) {
        let key = ActionUpdateKey(
            extensionIdentifier: context.uniqueIdentifier,
            panelID: panelID
        )
        actionFailures[key] = failure
        let action = panelID
            .flatMap { tabAdapters[$0] }
            .flatMap { context.action(for: $0) }
        enqueueActionUpdate(action: action, context: context, panelID: panelID)
    }

    private func loadExtension(at url: URL) async throws -> WKWebExtensionContext {
        try requireActive()
        let webExtension = try await WKWebExtension(resourceBaseURL: url)
        try requireActive()
        return try loadExtension(
            webExtension,
            installationName: url.lastPathComponent,
            supportsNativeMessaging: false,
            managedRecord: nil
        )
    }

    private func loadManagedRecord(
        _ record: BrowserWebExtensionManagedRecord
    ) async throws -> WKWebExtensionContext {
        let webExtension: WKWebExtension
        let installationName: String
        let supportsNativeMessaging: Bool
        switch record.source {
        case .directory(let filename, let expectedDigest),
             .catalogArchive(let filename, let expectedDigest, _):
            installationName = filename
            let packageURL = directory.appendingPathComponent(filename)
            let actualDigest = try await directoryRepository.digestForManagedPackage(at: packageURL)
            guard actualDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame else {
                throw BrowserWebExtensionInstallError.integrityMismatch
            }
            try requireActive()
            webExtension = try await WKWebExtension(
                resourceBaseURL: packageURL
            )
            supportsNativeMessaging = false
        case .safariApp(let reference):
            _ = try await verifySafariAppExtension(reference.bundleURL)
            try requireActive()
            installationName = reference.installationName
            webExtension = try await self.webExtension(for: reference)
            supportsNativeMessaging = true
        }
        try requireActive()
        if case .safariApp(let reference) = record.source {
            _ = try await verifySafariAppExtension(reference.bundleURL)
            try requireActive()
        }
        return try loadExtension(
            webExtension,
            installationName: installationName,
            supportsNativeMessaging: supportsNativeMessaging,
            managedRecord: record
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
            supportsNativeMessaging: true,
            managedRecord: nil
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
        supportsNativeMessaging: Bool,
        managedRecord: BrowserWebExtensionManagedRecord?
    ) throws -> WKWebExtensionContext {
        try requireActive()
        try validateLoadableManifest(webExtension)
        let context = WKWebExtensionContext(for: webExtension)
        // The persisted per-install identifier keeps storage stable across
        // updates while preventing removed extensions from donating storage to
        // a same-session reinstall with the same management identity.
        context.uniqueIdentifier = managedRecord.map {
            Self.contextIdentifier(for: $0)
        } ?? "cmux-browser-extension-\(installationName)"
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
        if let managedRecord {
            applyPersistedPermissions(in: context, record: managedRecord)
        } else {
            grantRequestedPermissions(in: context, for: webExtension)
        }
        try controller.load(context)
        loadedContexts.append(context)
        if let managedRecord {
            managedRecordIDsByContextIdentifier[context.uniqueIdentifier] = managedRecord.id
        }
        enqueueActionUpdate(action: nil, context: context, panelID: nil)
        return context
    }

    static let managedContextIdentifierPrefix = "cmux-browser-extension-"

    static func contextIdentifier(for record: BrowserWebExtensionManagedRecord) -> String {
        record.webExtensionContextIdentifier ?? contextIdentifier(for: record.id)
    }

    static func contextIdentifier(for logicalID: String) -> String {
        let digest = SHA256.hash(data: Data(logicalID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return managedContextIdentifierPrefix + digest
    }

    private static func freshContextIdentifier() -> String {
        managedContextIdentifierPrefix + UUID().uuidString.lowercased()
    }

    private func managedPackageURL(
        for record: BrowserWebExtensionManagedRecord
    ) -> URL? {
        switch record.source {
        case .directory(let filename, _), .catalogArchive(let filename, _, _):
            return directory.appendingPathComponent(filename)
        case .safariApp:
            return nil
        }
    }

    private func managedResourceURL(for record: BrowserWebExtensionManagedRecord) -> URL {
        switch record.source {
        case .directory(let filename, _), .catalogArchive(let filename, _, _):
            directory.appendingPathComponent(filename)
        case .safariApp(let reference):
            reference.bundleURL
        }
    }

    private func clearManagedLoadFailure(for record: BrowserWebExtensionManagedRecord) {
        failedManagedRecordIDs.remove(record.id)
        let failurePath = managedResourceURL(for: record).standardizedFileURL.path
        managedLoadFailureURLPaths.remove(failurePath)
        loadErrors.removeAll { $0.url.standardizedFileURL.path == failurePath }
    }

    private func applyPersistedPermissions(
        in context: WKWebExtensionContext,
        record: BrowserWebExtensionManagedRecord
    ) {
        context.grantedPermissions = Dictionary(uniqueKeysWithValues: record.grantedPermissions.map {
            (WKWebExtension.Permission(rawValue: $0.key), $0.value)
        })
        context.deniedPermissions = Dictionary(uniqueKeysWithValues: record.deniedPermissions.map {
            (WKWebExtension.Permission(rawValue: $0.key), $0.value)
        })
        context.grantedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: record.grantedMatchPatterns.compactMap {
            guard let pattern = try? WKWebExtension.MatchPattern(string: $0.key) else { return nil }
            return (pattern, $0.value)
        })
        context.deniedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: record.deniedMatchPatterns.compactMap {
            guard let pattern = try? WKWebExtension.MatchPattern(string: $0.key) else { return nil }
            return (pattern, $0.value)
        })
        context.hasRequestedOptionalAccessToAllHosts = record.hasRequestedOptionalAccessToAllHosts
    }

    func presentationSnapshot(for panelID: UUID? = nil) -> BrowserWebExtensionsPresentationSnapshot {
        let tabAdapter = panelID.flatMap { tabAdapters[$0] }
        let loadedItems = loadedContexts.map { context in
            let action = tabAdapter.flatMap { context.action(for: $0) }
            return presentationItem(for: context, action: action, panelID: panelID)
        }
        let loadedManagementIDs = Set(loadedItems.compactMap(\.managementID))
        let unloadedItems = managedRecords.values
            .filter { !loadedManagementIDs.contains($0.id) }
            .map { record in
                let loadFailed = record.isEnabled && failedManagedRecordIDs.contains(record.id)
                return BrowserWebExtensionPresentationItem(
                    id: Self.contextIdentifier(for: record),
                    managementID: record.id,
                    name: record.displayName,
                    version: record.version,
                    isEnabled: record.isEnabled && !loadFailed,
                    hasAction: false,
                    isToolbarPinned: record.isToolbarPinned,
                    isActionEnabled: false,
                    isAwaitingPopup: false,
                    loadFailure: loadFailed ? String(
                        localized: "browser.extensions.load.failed",
                        defaultValue: "The extension could not be loaded."
                    ) : nil,
                    badgeText: "",
                    iconData: nil,
                    grantedPermissions: Array(record.grantedPermissions.keys),
                    grantedHosts: Array(record.grantedMatchPatterns.keys),
                    capabilityNotices: record.capabilityNotices,
                    hasTrustedUpdateSource: Self.trustedUpdateAvailable(
                        for: record,
                        loadedVersion: nil
                    ) != nil,
                    canUpdate: Self.trustedUpdateAvailable(
                        for: record,
                        loadedVersion: nil
                    ) == true
                )
            }
        var failures = loadErrors.filter { failure in
            !managedLoadFailureURLPaths.contains(failure.url.standardizedFileURL.path)
        }.map { failure in
            BrowserWebExtensionPresentationFailure(
                id: failure.url.lastPathComponent,
                entryName: failure.url.lastPathComponent,
                message: String(
                    localized: "browser.extensions.load.failed",
                    defaultValue: "The extension could not be loaded."
                )
            )
        }
        if profileRuntime.phase == .degraded(.loadDeadlineExceeded) {
            failures.append(BrowserWebExtensionPresentationFailure(
                id: "load-deadline",
                entryName: String(
                    localized: "browser.extensions.load.timeout.name",
                    defaultValue: "Extension loader"
                ),
                message: String(
                    localized: "browser.extensions.load.timeout",
                    defaultValue: "Extension loading timed out. Retry to restore any extension that did not finish loading."
                )
            ))
        }
        return BrowserWebExtensionsPresentationSnapshot(
            state: isLoaded ? .ready : .loading,
            extensions: (loadedItems + unloadedItems).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            failures: failures
        )
    }

    static func trustedUpdateAvailable(
        for record: BrowserWebExtensionManagedRecord,
        loadedVersion: String?,
        catalog: BrowserWebExtensionCatalog = .production
    ) -> Bool? {
        switch record.source {
        case .catalogArchive(_, let installedDigest, let catalogID):
            guard let entry = catalog.entry(id: catalogID) else { return nil }
            return installedDigest.caseInsensitiveCompare(entry.packageSHA256) != .orderedSame
                || record.version != entry.version
        case .safariApp:
            guard let loadedVersion else { return false }
            return loadedVersion != record.version
        case .directory:
            return nil
        }
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
        let context = try resolvedContext(matching: identifier)
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
        let context = try resolvedContext(matching: identifier)
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
        if let exactContext = loadedContexts.first(where: { $0.uniqueIdentifier == identifier }) {
            return [exactContext]
        }
        let folded = identifier.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return loadedContexts.filter { context in
            let name = context.webExtension.displayName ?? ""
            return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == folded
        }
    }

    private func resolvedContext(matching identifier: String) throws -> WKWebExtensionContext {
        if let exactContext = loadedContexts.first(where: { $0.uniqueIdentifier == identifier }) {
            return exactContext
        }
        let matches = matchingContexts(identifier)
        guard !matches.isEmpty else {
            throw BrowserWebExtensionDiagnosticsError.extensionNotFound(identifier)
        }
        guard matches.count == 1, let match = matches.first else {
            throw BrowserWebExtensionDiagnosticsError.ambiguousExtensionName(identifier)
        }
        return match
    }

    func pageConfiguration(
        for url: URL
    ) -> (baseURL: URL, configuration: WKWebViewConfiguration)? {
        guard let context = loadedContexts.first(where: {
            Self.sameOrigin(url, $0.baseURL)
        }), let configuration = context.webViewConfiguration else {
            return nil
        }
        registerExtensionPageConfiguration(configuration, for: context)
        return (context.baseURL, configuration)
    }

    func ownsWebExtensionPageConfiguration(
        _ configuration: WKWebViewConfiguration
    ) -> Bool {
        guard configuration.webExtensionController === controller else { return false }
        let userContentController = configuration.userContentController
        compactExtensionPageContentControllers()
        guard let registration = extensionPageContentControllers[
            ObjectIdentifier(userContentController)
        ], registration.userContentController === userContentController else {
            return false
        }
        return loadedContexts.contains {
            $0.uniqueIdentifier == registration.extensionIdentifier
        }
    }

    private func registerExtensionPageConfiguration(
        _ configuration: WKWebViewConfiguration,
        for context: WKWebExtensionContext
    ) {
        compactExtensionPageContentControllers()
        let userContentController = configuration.userContentController
        extensionPageContentControllers[ObjectIdentifier(userContentController)] =
            ExtensionPageContentControllerRegistration(
                userContentController: userContentController,
                extensionIdentifier: context.uniqueIdentifier
            )
    }

    private func compactExtensionPageContentControllers() {
        extensionPageContentControllers = extensionPageContentControllers.filter {
            $0.value.userContentController != nil
        }
    }

    private func removeExtensionPageConfigurations(
        for context: WKWebExtensionContext
    ) {
        extensionPageContentControllers = extensionPageContentControllers.filter {
            $0.value.userContentController != nil
                && $0.value.extensionIdentifier != context.uniqueIdentifier
        }
    }

    private func unloadContext(_ context: WKWebExtensionContext) throws {
        try controller.unload(context)
        removeExtensionPageConfigurations(for: context)
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
    ) -> BrowserWebExtensionPresentationItem {
        let key = ActionUpdateKey(
            extensionIdentifier: context.uniqueIdentifier,
            panelID: panelID
        )
        let record = managedRecordIDsByContextIdentifier[context.uniqueIdentifier]
            .flatMap { managedRecords[$0] }
        return BrowserWebExtensionPresentationItem(
            id: context.uniqueIdentifier,
            managementID: record?.id,
            name: context.webExtension.displayName ?? context.uniqueIdentifier,
            version: context.webExtension.version ?? record?.version ?? "",
            isEnabled: record?.isEnabled ?? true,
            hasAction: Self.definesAction(context.webExtension),
            isToolbarPinned: record?.isToolbarPinned
                ?? toolbarPinnedExtensionIdentifiers.contains(context.uniqueIdentifier),
            isActionEnabled: action?.isEnabled ?? Self.definesAction(context.webExtension),
            isAwaitingPopup: panelID.map {
                actionsAwaitingReadyPopup.contains(ActionInvocationKey(
                    extensionIdentifier: context.uniqueIdentifier,
                    panelID: $0
                ))
            } ?? false,
            actionFailure: panelID.flatMap {
                expiredPopupHandoffs.contains(ActionInvocationKey(
                    extensionIdentifier: context.uniqueIdentifier,
                    panelID: $0
                )) ? .popupTimedOut : actionFailures[ActionUpdateKey(
                    extensionIdentifier: context.uniqueIdentifier,
                    panelID: $0
                )]
            } ?? actionFailures[ActionUpdateKey(
                extensionIdentifier: context.uniqueIdentifier,
                panelID: nil
            )],
            badgeText: action?.badgeText ?? "",
            iconData: presentationIconData(
                for: action,
                webExtension: context.webExtension,
                cacheKey: key
            ),
            grantedPermissions: record.map { Array($0.grantedPermissions.keys) } ?? [],
            grantedHosts: record.map { Array($0.grantedMatchPatterns.keys) } ?? [],
            capabilityNotices: record?.capabilityNotices ?? [],
            hasTrustedUpdateSource: record.flatMap {
                Self.trustedUpdateAvailable(
                    for: $0,
                    loadedVersion: context.webExtension.version
                )
            } != nil,
            canUpdate: record.flatMap {
                Self.trustedUpdateAvailable(
                    for: $0,
                    loadedVersion: context.webExtension.version
                )
            } == true
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
                self.profileRuntime.publishActionUpdate(
                    BrowserWebExtensionActionUpdate(
                        profileID: self.profileRuntime.profileID,
                        panelID: key.panelID,
                        item: self.presentationItem(
                            for: update.context,
                            action: update.action,
                            panelID: key.panelID
                        )
                    )
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
        guard let raster = BrowserWebExtensionPresentationIconEncoder.rasterize(
            image,
            size: size
        ) else {
            presentationIconCache.removeValue(forKey: cacheKey)
            return nil
        }
        if let cached = presentationIconCache[cacheKey],
           cached.signature == raster.signature {
            return cached.data
        }
        let data = BrowserWebExtensionPresentationIconEncoder.pngData(for: raster.image)
        presentationIconCache[cacheKey] = PresentationIconCacheEntry(
            signature: raster.signature,
            data: data
        )
        return data
    }
}

enum BrowserWebExtensionPresentationIconEncoder {
    struct Raster {
        let signature: String
        let image: CGImage
    }

    static func rasterize(_ image: NSImage, size: CGSize) -> Raster? {
        let pixelWidth = max(1, Int(size.width.rounded(.up)))
        let pixelHeight = max(1, Int(size.height.rounded(.up)))
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let sourceImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        let scale = min(
            CGFloat(pixelWidth) / CGFloat(sourceImage.width),
            CGFloat(pixelHeight) / CGFloat(sourceImage.height)
        )
        let drawSize = CGSize(
            width: CGFloat(sourceImage.width) * scale,
            height: CGFloat(sourceImage.height) * scale
        )
        context.draw(sourceImage, in: CGRect(
            x: (CGFloat(pixelWidth) - drawSize.width) / 2,
            y: (CGFloat(pixelHeight) - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        ))
        guard let cgImage = context.makeImage(),
              let providerData = cgImage.dataProvider?.data else { return nil }
        let metadata = [
            cgImage.width,
            cgImage.height,
            cgImage.bitsPerComponent,
            cgImage.bitsPerPixel,
            cgImage.bytesPerRow,
            Int(cgImage.bitmapInfo.rawValue),
        ].map(String.init).joined(separator: ":")
        var hasher = SHA256()
        hasher.update(data: Data(metadata.utf8))
        hasher.update(data: providerData as Data)
        let signature = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Raster(signature: signature, image: cgImage)
    }

    static func pngData(for image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

@available(macOS 15.4, *)
extension BrowserWebExtensionsManager: WKWebExtensionControllerDelegate {
    private func openExtensionTab(
        in windowAdapter: BrowserWebExtensionWindowAdapter,
        index: Int,
        shouldBeActive: Bool,
        shouldAddToSelection: Bool,
        url: URL?,
        parentTab: (any WKWebExtensionTab)? = nil,
        shouldBePinned: Bool = false,
        shouldBeMuted: Bool = false,
        shouldReaderModeBeActive: Bool = false
    ) throws -> BrowserWebExtensionTabAdapter {
        guard !shouldReaderModeBeActive else {
            throw BrowserWebExtensionNewTabError.readerModeUnsupported
        }
        if let parentTab {
            guard let parentAdapter = parentTab as? BrowserWebExtensionTabAdapter,
                  parentAdapter.windowAdapter === windowAdapter else {
                throw BrowserWebExtensionNewTabError.parentTabUnavailable
            }
        }
        guard let panel = windowAdapter.createTab(
            index,
            shouldBeActive,
            shouldAddToSelection
        ), let tabAdapter = tabAdapters[panel.id] else {
            throw BrowserWebExtensionNewTabError.creationFailed
        }
        let closeOnFailure = { _ = windowAdapter.closePanel(panel.id) }
        if let parentAdapter = parentTab as? BrowserWebExtensionTabAdapter {
            tabAdapter.parentAdapter = parentAdapter
        }
        if shouldBePinned, !windowAdapter.setPanelPinned(panel.id, true) {
            closeOnFailure()
            throw BrowserWebExtensionNewTabError.pinFailed
        }
        if shouldBeMuted, !panel.setMuted(true) {
            closeOnFailure()
            throw BrowserWebExtensionNewTabError.muteFailed
        }
        if let url {
            panel.navigate(to: url)
        }
        return tabAdapter
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        let popupWindows = popupWindowAdapters.values.sorted { lhs, rhs in
            let lhsKey = lhs.popupController?.webExtensionHostWindow.isKeyWindow == true
            let rhsKey = rhs.popupController?.webExtensionHostWindow.isKeyWindow == true
            if lhsKey != rhsKey { return lhsKey }
            return lhs.ownerID.uuidString < rhs.ownerID.uuidString
        }
        return popupWindows.map { $0 as any WKWebExtensionWindow }
            + orderedWindowAdapters().map { $0 as any WKWebExtensionWindow }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        guard NSApp.isActive else { return nil }
        if let popupWindow = popupWindowAdapters.values.first(where: {
            $0.popupController?.webExtensionHostWindow.isKeyWindow == true
        }) {
            return popupWindow
        }
        return focusedWindowAdapter()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        if let popupWindowAdapter = configuration.window as? BrowserWebExtensionPopupWindowAdapter,
           let popupTabAdapter = popupWindowAdapter.tabAdapter {
            popupTabAdapter.duplicate(using: configuration, for: extensionContext, completionHandler: completionHandler)
            return
        }
        let windowAdapter = (configuration.window as? BrowserWebExtensionWindowAdapter)
            ?? focusedWindowAdapter()
            ?? orderedWindowAdapters().first
        guard let windowAdapter else {
            completionHandler(nil, BrowserWebExtensionNewTabError.creationFailed)
            return
        }
        do {
            let tabAdapter = try openExtensionTab(
                in: windowAdapter,
                index: configuration.index,
                shouldBeActive: configuration.shouldBeActive,
                shouldAddToSelection: configuration.shouldAddToSelection,
                url: configuration.url,
                parentTab: configuration.parentTab,
                shouldBePinned: configuration.shouldBePinned,
                shouldBeMuted: configuration.shouldBeMuted,
                shouldReaderModeBeActive: configuration.shouldReaderModeBeActive
            )
            completionHandler(tabAdapter, nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let optionsPageURL = extensionContext.optionsPageURL else {
            completionHandler(BrowserWebExtensionNewTabError.optionsPageUnavailable)
            return
        }
        guard let windowAdapter = focusedWindowAdapter()
                ?? orderedWindowAdapters().first else {
            completionHandler(BrowserWebExtensionNewTabError.creationFailed)
            return
        }
        do {
            _ = try openExtensionTab(
                in: windowAdapter,
                index: NSNotFound,
                shouldBeActive: true,
                shouldAddToSelection: true,
                url: optionsPageURL
            )
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let key = actionInvocationKey(for: action, extensionContext: extensionContext)
        if let key, expiredPopupHandoffs.contains(key) {
            cancelPopupHandoff(for: key)
            completionHandler(BrowserWebExtensionActionError.unavailable)
            return
        }
        if let key, actionsAwaitingReadyPopup.remove(key) != nil {
            popupHandoffDeadlineTasks.removeValue(forKey: key)?.cancel()
        }
        do {
            try showPopup(action, for: extensionContext, key: key)
            if let key { refreshActionPresentation(for: key) }
            completionHandler(nil)
        } catch {
            if let key { cancelPopupHandoff(for: key) }
            completionHandler(error)
        }
    }

    private func showPopup(
        _ action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        key: ActionInvocationKey?
    ) throws {
        guard let popover = action.popupPopover else {
            throw BrowserWebExtensionActionError.missingPopupAnchor
        }
        let popoverID = ObjectIdentifier(popover)
        if let presented = presentedPopups[popoverID] {
            presented.invocationKey = key
            if let webView = action.popupWebView {
                popupWebViews[extensionContext.uniqueIdentifier] = WeakPopupWebView(webView)
            }
            return
        }
        var retainedAnchorView: NSView?
        var anchor: (view: NSView, rect: NSRect)?
        var placementPlan: BrowserWebExtensionPopupPlacementLock.Plan?
        if !popover.isShown {
            guard let resolvedAnchor = popupAnchor(for: action, extensionContext: extensionContext) else {
                throw BrowserWebExtensionActionError.missingPopupAnchor
            }
            anchor = resolvedAnchor
            retainedAnchorView = resolvedAnchor.view
            popover.behavior = .transient
            popover.animates = false
            guard let resolvedPlacementPlan = BrowserWebExtensionPopupPlacementLock.plan(
                popover: popover,
                anchorView: resolvedAnchor.view,
                anchorRect: resolvedAnchor.rect
            ) else {
                throw BrowserWebExtensionActionError.missingPopupAnchor
            }
            placementPlan = resolvedPlacementPlan
            if popover.contentSize.height > resolvedPlacementPlan.maximumContentHeight {
                popover.contentSize.height = resolvedPlacementPlan.maximumContentHeight
            }
        } else {
            retainedAnchorView = key.flatMap { lastActionInvocations[$0]?.anchorView }
        }
        let popupWebView = action.popupWebView
        if let popupWebView {
            popupWebViews[extensionContext.uniqueIdentifier] = WeakPopupWebView(popupWebView)
        }
        let tabAdapter = action.associatedTab as? BrowserWebExtensionTabAdapter
        let presented = PresentedActionPopup(
            popover: popover,
            extensionIdentifier: extensionContext.uniqueIdentifier,
            panelID: key?.panelID ?? tabAdapter?.panel?.id,
            invocationKey: key,
            anchorView: retainedAnchorView,
            action: action,
            context: extensionContext,
            controller: controller,
            tabAdapter: tabAdapter,
            popupWebView: popupWebView,
            placementLock: nil,
            owner: self
        )
        presentedPopups[popoverID] = presented
        if let anchor, let placementPlan {
            popover.show(
                relativeTo: anchor.rect,
                of: anchor.view,
                preferredEdge: placementPlan.preferredEdge
            )
            guard let placementLock = BrowserWebExtensionPopupPlacementLock(
                popover: popover,
                anchorView: anchor.view,
                anchorRect: anchor.rect,
                side: placementPlan.side
            ) else {
                presented.requestLifecycleClose()
                throw BrowserWebExtensionActionError.missingPopupAnchor
            }
            presented.attachPlacementLock(placementLock)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        let panelID = (action.associatedTab as? BrowserWebExtensionTabAdapter)?.panel?.id
        enqueueActionUpdate(action: action, context: context, panelID: panelID)
        let pendingKeys = pendingActionInvocations.keys
            .filter { $0.extensionIdentifier == context.uniqueIdentifier }
            .sorted { $0.panelID.uuidString < $1.panelID.uuidString }
        for key in pendingKeys {
            guard !actionsAwaitingReadyPopup.contains(key),
                  let tabAdapter = tabAdapters[key.panelID],
                  let panelAction = context.action(for: tabAdapter),
                  panelAction.presentsPopup else {
                continue
            }
            actionsAwaitingReadyPopup.insert(key)
            performExtensionAction(context, tabAdapter)
        }
    }

    private func actionInvocationKey(
        for action: WKWebExtension.Action,
        extensionContext: WKWebExtensionContext
    ) -> ActionInvocationKey? {
        if let panelID = (action.associatedTab as? BrowserWebExtensionTabAdapter)?.panel?.id {
            return ActionInvocationKey(
                extensionIdentifier: extensionContext.uniqueIdentifier,
                panelID: panelID
            )
        }
        let extensionIdentifier = extensionContext.uniqueIdentifier
        if let pending = pendingActionInvocations.keys
            .filter({ $0.extensionIdentifier == extensionIdentifier })
            .sorted(by: { $0.panelID.uuidString < $1.panelID.uuidString })
            .first {
            return pending
        }
        if let expired = expiredPopupHandoffs
            .filter({ $0.extensionIdentifier == extensionIdentifier })
            .sorted(by: { $0.panelID.uuidString < $1.panelID.uuidString })
            .first {
            return expired
        }
        let panelID = focusedWindowAdapter()?.activePanelID()
            ?? orderedWindowAdapters().first?.compactTabs().first?.panel?.id
        return panelID.map {
            ActionInvocationKey(extensionIdentifier: extensionIdentifier, panelID: $0)
        }
    }

    private func popupAnchor(
        for action: WKWebExtension.Action,
        extensionContext: WKWebExtensionContext
    ) -> (view: NSView, rect: NSRect)? {
        let key = actionInvocationKey(for: action, extensionContext: extensionContext)
        let associatedPanel = key.flatMap { tabAdapters[$0.panelID]?.panel }

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

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        guard let request = permissionRequest(
            for: extensionContext,
            tab: tab,
            permissions: permissions.map(\.rawValue)
        ) else {
            completionHandler([], nil)
            return
        }
        let resolution = PendingPermissionResolution {
            completionHandler([], nil)
        }
        enqueuePermissionPrompt(
            request,
            context: extensionContext,
            resolution: resolution,
            apply: { decision in
                let status: WKWebExtensionContext.PermissionStatus = decision == .grant
                    ? .grantedExplicitly : .deniedExplicitly
                for permission in permissions {
                    extensionContext.setPermissionStatus(status, for: permission)
                }
            },
            complete: { decision in
                completionHandler(decision == .grant ? permissions : [], nil)
            }
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        guard let request = permissionRequest(
            for: extensionContext,
            tab: tab,
            urls: Array(urls)
        ) else {
            completionHandler([], nil)
            return
        }
        let resolution = PendingPermissionResolution {
            completionHandler([], nil)
        }
        enqueuePermissionPrompt(
            request,
            context: extensionContext,
            resolution: resolution,
            apply: { decision in
                let status: WKWebExtensionContext.PermissionStatus = decision == .grant
                    ? .grantedExplicitly : .deniedExplicitly
                for url in urls {
                    extensionContext.setPermissionStatus(status, for: url)
                }
            },
            complete: { decision in
                completionHandler(decision == .grant ? urls : [], nil)
            }
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        guard let request = permissionRequest(
            for: extensionContext,
            tab: tab,
            matchPatterns: Array(matchPatterns)
        ) else {
            completionHandler([], nil)
            return
        }
        let resolution = PendingPermissionResolution {
            completionHandler([], nil)
        }
        enqueuePermissionPrompt(
            request,
            context: extensionContext,
            resolution: resolution,
            apply: { decision in
                let status: WKWebExtensionContext.PermissionStatus = decision == .grant
                    ? .grantedExplicitly : .deniedExplicitly
                for pattern in matchPatterns {
                    extensionContext.setPermissionStatus(status, for: pattern)
                }
            },
            complete: { decision in
                completionHandler(decision == .grant ? matchPatterns : [], nil)
            }
        )
    }

    private func permissionRequest(
        for context: WKWebExtensionContext,
        tab: (any WKWebExtensionTab)?,
        permissions: [String] = [],
        urls: [URL] = [],
        matchPatterns: [WKWebExtension.MatchPattern] = []
    ) -> BrowserWebExtensionPermissionRequest? {
        guard let managementID = managedRecordIDsByContextIdentifier[context.uniqueIdentifier],
              managedRecords[managementID] != nil,
              loadedContext(managementID: managementID) === context else {
            return nil
        }
        let optionalPermissions = Set(context.webExtension.optionalPermissions.map(\.rawValue))
        guard Set(permissions).isSubset(of: optionalPermissions) else { return nil }
        let optionalPatterns = context.webExtension.optionalPermissionMatchPatterns
        guard urls.allSatisfy({ url in
            optionalPatterns.contains { $0.matches(url) }
        }) else { return nil }
        guard matchPatterns.allSatisfy({ requestedPattern in
            optionalPatterns.contains { $0.matches(requestedPattern) }
        }) else { return nil }
        let hosts = urls.map(\.absoluteString) + matchPatterns.map(\.string)
        return BrowserWebExtensionPermissionRequest(
            profileID: profileRuntime.profileID,
            managementID: managementID,
            extensionName: context.webExtension.displayName ?? managementID,
            permissions: permissions,
            hosts: hosts
        )
    }

    private func enqueuePermissionPrompt(
        _ request: BrowserWebExtensionPermissionRequest,
        context: WKWebExtensionContext,
        resolution: PendingPermissionResolution,
        apply: @escaping @MainActor (BrowserWebExtensionPermissionDecision) -> Void,
        complete: @escaping @MainActor (BrowserWebExtensionPermissionDecision) -> Void
    ) {
        profileRuntime.publishPermissionRequest(request)
        pendingPermissionResolutions[request.id] = resolution
        let contextIdentifier = ObjectIdentifier(context)
        permissionRequestContextIdentifiers[request.id] = contextIdentifier
        let previousTask = permissionPromptTail
        let presenter = presentPermissionPrompt
        let window = permissionPromptWindow(for: context)
        let task = Task { @MainActor [weak self] in
            if let previousTask { await previousTask.value }
            guard let self,
                  !self.isShutDown,
                  !Task.isCancelled,
                  self.permissionRequestContextIdentifiers[request.id] == contextIdentifier,
                  self.loadedContext(managementID: request.managementID) === context else {
                resolution.finishDenying()
                return
            }
            let decision = await presenter(request, window)
            guard !self.isShutDown, !Task.isCancelled,
                  self.permissionRequestContextIdentifiers[request.id] == contextIdentifier,
                  self.loadedContext(managementID: request.managementID) === context,
                  let previousRecord = self.managedRecords[request.managementID] else {
                resolution.finishDenying()
                self.finishPermissionPrompt(id: request.id)
                return
            }
            apply(decision)
            do {
                try await self.persistPermissionState(
                    context,
                    managementID: request.managementID
                )
                resolution.finish { complete(decision) }
            } catch {
                self.applyPersistedPermissions(in: context, record: previousRecord)
                resolution.finishDenying()
            }
            self.finishPermissionPrompt(id: request.id)
        }
        permissionPromptTasks[request.id] = task
        permissionPromptTail = task
    }

    private func finishPermissionPrompt(id: UUID) {
        pendingPermissionResolutions.removeValue(forKey: id)
        permissionPromptTasks.removeValue(forKey: id)
        permissionRequestContextIdentifiers.removeValue(forKey: id)
    }

    private func cancelPermissionPrompts(for context: WKWebExtensionContext) {
        let contextIdentifier = ObjectIdentifier(context)
        let requestIDs = permissionRequestContextIdentifiers.compactMap { requestID, identifier in
            identifier == contextIdentifier ? requestID : nil
        }
        guard !requestIDs.isEmpty else { return }
        for requestID in requestIDs {
            pendingPermissionResolutions.removeValue(forKey: requestID)?.finishDenying()
            permissionPromptTasks.removeValue(forKey: requestID)?.cancel()
            permissionRequestContextIdentifiers.removeValue(forKey: requestID)
        }
        permissionPromptTail = nil
    }

    private func permissionPromptWindow(for context: WKWebExtensionContext) -> NSWindow? {
        let panels = tabAdapters.values.compactMap(\.panel)
        return panels.first(where: { $0.webView.window?.isKeyWindow == true })?.webView.window
            ?? panels.first?.webView.window
            ?? NSApp.keyWindow
    }

    private func persistPermissionState(
        _ context: WKWebExtensionContext,
        managementID: String
    ) async throws {
        guard loadedContext(managementID: managementID) === context,
              var record = managedRecords[managementID] else {
            throw BrowserWebExtensionManagementError.extensionNotFound
        }
        let previousRecord = record
        record.grantedPermissions = Dictionary(uniqueKeysWithValues: context.grantedPermissions.map {
            ($0.key.rawValue, $0.value)
        })
        record.deniedPermissions = Dictionary(uniqueKeysWithValues: context.deniedPermissions.map {
            ($0.key.rawValue, $0.value)
        })
        record.grantedMatchPatterns = Dictionary(
            uniqueKeysWithValues: context.grantedPermissionMatchPatterns.map {
                ($0.key.string, $0.value)
            }
        )
        record.deniedMatchPatterns = Dictionary(
            uniqueKeysWithValues: context.deniedPermissionMatchPatterns.map {
                ($0.key.string, $0.value)
            }
        )
        record.hasRequestedOptionalAccessToAllHosts = context.hasRequestedOptionalAccessToAllHosts
        guard try await directoryRepository.replaceManagedRecord(
            record,
            expectedPreviousRecord: previousRecord,
            in: directory
        ), loadedContext(managementID: managementID) === context else {
            throw BrowserWebExtensionManagementError.extensionNotFound
        }
        managedRecords[managementID] = record
        profileRuntime.invalidateSnapshot()
    }

    func orderedWindowAdapters() -> [BrowserWebExtensionWindowAdapter] {
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

    private func presentedPopupDidClose(_ popup: PresentedActionPopup, event: NSEvent?) {
        let popoverID = ObjectIdentifier(popup.popover)
        guard presentedPopups[popoverID] === popup,
              !popup.isLifecycleClose,
              let key = popup.invocationKey else {
            return
        }
        cancelPopupHandoff(for: key)
        guard popupClosuresRequestedByActionButton.remove(key) == nil,
              let event,
              event.type == .leftMouseDown || event.type == .rightMouseDown,
              let anchor = popup.anchorView,
              event.window === anchor.window,
              anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) else {
            return
        }
        dismissedPopupKeys.insert(key)
    }

    private func presentedPopupDidQuiesce(_ popup: PresentedActionPopup) {
        let popoverID = ObjectIdentifier(popup.popover)
        guard presentedPopups[popoverID] === popup else { return }
        presentedPopups.removeValue(forKey: popoverID)
        if !presentedPopups.values.contains(where: {
            $0.extensionIdentifier == popup.extensionIdentifier
        }) {
            popupWebViews.removeValue(forKey: popup.extensionIdentifier)
            let waiters = popupQuiescenceWaiters.removeValue(
                forKey: popup.extensionIdentifier
            ) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
        if let panelID = popup.panelID {
            finalizePanelUnregistrationIfPossible(panelID)
        }
        if isShutDown {
            finalizeShutdown()
        }
    }

#if DEBUG
    func waitForPopupQuiescenceForTesting(
        extensionIdentifier: String
    ) async {
        await closePresentedPopups(forExtensionIdentifier: extensionIdentifier)
    }

    struct DebugTransientStateCounts: Equatable {
        let pendingInvocations: Int
        let lastInvocations: Int
        let deadlineTasks: Int
        let awaitingPopups: Int
        let expiredPopups: Int
        let dismissedPopups: Int
        let closureRequests: Int
        let popoverKeys: Int
        let popupWebViews: Int
        let pendingUpdates: Int
        let iconCacheEntries: Int
        let actionFailures: Int

        var total: Int {
            pendingInvocations + lastInvocations + deadlineTasks + awaitingPopups
                + expiredPopups + dismissedPopups + closureRequests + popoverKeys
                + popupWebViews + pendingUpdates + iconCacheEntries + actionFailures
        }
    }

    func seedTransientStateForTesting(
        panelID: UUID,
        extensionIdentifier: String,
        context: WKWebExtensionContext
    ) -> (popover: NSPopover, webView: WKWebView) {
        let invocationKey = ActionInvocationKey(
            extensionIdentifier: extensionIdentifier,
            panelID: panelID
        )
        let updateKey = ActionUpdateKey(
            extensionIdentifier: extensionIdentifier,
            panelID: panelID
        )
        let invocation = PendingActionInvocation(anchorView: nil, panelID: panelID)
        pendingActionInvocations[invocationKey] = [invocation]
        lastActionInvocations[invocationKey] = invocation
        popupHandoffDeadlineTasks[invocationKey] = Task {}
        actionsAwaitingReadyPopup.insert(invocationKey)
        expiredPopupHandoffs.insert(invocationKey)
        dismissedPopupKeys.insert(invocationKey)
        popupClosuresRequestedByActionButton.insert(invocationKey)
        let popover = NSPopover()
        debugSyntheticPopupKeys[ObjectIdentifier(popover)] = invocationKey
        let webView = WKWebView()
        popupWebViews[extensionIdentifier] = WeakPopupWebView(webView)
        pendingActionUpdates[updateKey] = PendingActionUpdate(action: nil, context: context)
        presentationIconCache[updateKey] = PresentationIconCacheEntry(
            signature: "test",
            data: Data([0])
        )
        actionFailures[updateKey] = .actionUnavailable
        return (popover, webView)
    }

    func seedPendingActionInvocationForTesting(
        panelID: UUID,
        extensionIdentifier: String,
        anchorView: NSView?
    ) {
        let key = ActionInvocationKey(
            extensionIdentifier: extensionIdentifier,
            panelID: panelID
        )
        let invocation = PendingActionInvocation(
            anchorView: anchorView,
            panelID: panelID
        )
        cancelPopupHandoff(for: key)
        pendingActionInvocations[key] = [invocation]
        lastActionInvocations[key] = invocation
    }

    func transientStateCountsForTesting(
        panelID: UUID,
        extensionIdentifier: String
    ) -> DebugTransientStateCounts {
        let matchesInvocation: (ActionInvocationKey) -> Bool = {
            $0.panelID == panelID && $0.extensionIdentifier == extensionIdentifier
        }
        let matchesUpdate: (ActionUpdateKey) -> Bool = {
            $0.panelID == panelID && $0.extensionIdentifier == extensionIdentifier
        }
        return DebugTransientStateCounts(
            pendingInvocations: pendingActionInvocations.keys.filter(matchesInvocation).count,
            lastInvocations: lastActionInvocations.keys.filter(matchesInvocation).count,
            deadlineTasks: popupHandoffDeadlineTasks.keys.filter(matchesInvocation).count,
            awaitingPopups: actionsAwaitingReadyPopup.filter(matchesInvocation).count,
            expiredPopups: expiredPopupHandoffs.filter(matchesInvocation).count,
            dismissedPopups: dismissedPopupKeys.filter(matchesInvocation).count,
            closureRequests: popupClosuresRequestedByActionButton.filter(matchesInvocation).count,
            popoverKeys: presentedPopups.values.filter {
                $0.invocationKey.map(matchesInvocation) == true
            }.count + debugSyntheticPopupKeys.values.filter(matchesInvocation).count,
            popupWebViews: popupWebViews[extensionIdentifier]?.webView == nil ? 0 : 1,
            pendingUpdates: pendingActionUpdates.keys.filter(matchesUpdate).count,
            iconCacheEntries: presentationIconCache.keys.filter(matchesUpdate).count,
            actionFailures: actionFailures.keys.filter(matchesUpdate).count
        )
    }

#endif
}

/// Keeps a WebExtension action popover on the browser side selected for the
/// initial click. The side and bounded content size are chosen before `show`,
/// then the lock is installed synchronously so later AppKit size changes reuse
/// the same chosen-side origin instead of flipping edges.
@MainActor
final class BrowserWebExtensionPopupPlacementLock {
    enum Side: Equatable {
        case below
        case above
    }

    struct Plan: Equatable {
        let side: Side
        let preferredEdge: NSRectEdge
        let maximumContentHeight: CGFloat
    }

    private static let estimatedPopoverChromeHeight: CGFloat = 24
    private weak var popupWindow: NSWindow?
    private weak var popover: NSPopover?
    private weak var anchorView: NSView?
    private let anchorRect: NSRect
    private let side: Side
    private var observers: [NSObjectProtocol] = []
    private var isApplyingFrame = false

    init?(
        popover: NSPopover,
        anchorView: NSView,
        anchorRect: NSRect,
        side: Side
    ) {
        guard anchorView.window != nil,
              let popupWindow = popover.contentViewController?.view.window else {
            return nil
        }
        self.popupWindow = popupWindow
        self.popover = popover
        self.anchorView = anchorView
        self.anchorRect = anchorRect
        self.side = side

        applyLockedFrame()
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(center.addObserver(
                forName: name,
                object: popupWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyLockedFrame()
                }
            })
        }
        popupWindow.displayIfNeeded()
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func applyLockedFrame() {
        guard !isApplyingFrame,
              let popupWindow,
              let popover,
              let anchorView,
              let anchorWindow = anchorView.window else { return }
        isApplyingFrame = true
        defer { isApplyingFrame = false }

        let anchorWindowRect = anchorView.convert(anchorRect, to: nil)
        let anchorScreenRect = anchorWindow.convertToScreen(anchorWindowRect)
        let visibleFrame = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        if let visibleFrame {
            let fittedContentHeight = Self.contentHeightFittingChosenSide(
                side: side,
                popupHeight: popupWindow.frame.height,
                contentHeight: popover.contentSize.height,
                anchorScreenRect: anchorScreenRect,
                visibleFrame: visibleFrame
            )
            if abs(popover.contentSize.height - fittedContentHeight) > 0.5 {
                popover.contentSize.height = fittedContentHeight
            }
        }
        let origin = Self.lockedOrigin(
            side: side,
            popupSize: popupWindow.frame.size,
            anchorScreenRect: anchorScreenRect,
            visibleFrame: visibleFrame
        )
        if abs(popupWindow.frame.origin.x - origin.x) > 0.5
            || abs(popupWindow.frame.origin.y - origin.y) > 0.5 {
            popupWindow.setFrameOrigin(origin)
        }
    }

    static func contentHeightFittingChosenSide(
        side: Side,
        popupHeight: CGFloat,
        contentHeight: CGFloat,
        anchorScreenRect: NSRect,
        visibleFrame: NSRect
    ) -> CGFloat {
        let availableHeight = availableHeight(
            for: side,
            anchorScreenRect: anchorScreenRect,
            visibleFrame: visibleFrame
        )
        let overflow = popupHeight - availableHeight
        guard overflow > 0.5, contentHeight > 1 else { return contentHeight }
        return max(1, contentHeight - overflow)
    }

    static func plan(
        popover: NSPopover,
        anchorView: NSView,
        anchorRect: NSRect
    ) -> Plan? {
        guard let anchorWindow = anchorView.window,
              let visibleFrame = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return nil
        }
        let anchorWindowRect = anchorView.convert(anchorRect, to: nil)
        let anchorScreenRect = anchorWindow.convertToScreen(anchorWindowRect)
        return plan(
            contentHeight: popover.contentSize.height,
            anchorScreenRect: anchorScreenRect,
            visibleFrame: visibleFrame
        )
    }

    static func plan(
        contentHeight: CGFloat,
        anchorScreenRect: NSRect,
        visibleFrame: NSRect
    ) -> Plan {
        let belowHeight = availableHeight(
            for: .below,
            anchorScreenRect: anchorScreenRect,
            visibleFrame: visibleFrame
        )
        let aboveHeight = availableHeight(
            for: .above,
            anchorScreenRect: anchorScreenRect,
            visibleFrame: visibleFrame
        )
        let requestedWindowHeight = contentHeight + estimatedPopoverChromeHeight
        let side: Side
        if requestedWindowHeight <= belowHeight {
            side = .below
        } else if requestedWindowHeight <= aboveHeight {
            side = .above
        } else {
            side = belowHeight >= aboveHeight ? .below : .above
        }
        let available = side == .below ? belowHeight : aboveHeight
        return Plan(
            side: side,
            preferredEdge: side == .below ? .minY : .maxY,
            maximumContentHeight: max(1, available - estimatedPopoverChromeHeight)
        )
    }

    static func lockedOrigin(
        side: Side,
        popupSize: NSSize,
        anchorScreenRect: NSRect,
        visibleFrame: NSRect?
    ) -> NSPoint {
        var x = anchorScreenRect.midX - popupSize.width / 2
        if let visibleFrame {
            x = min(
                max(x, visibleFrame.minX),
                max(visibleFrame.minX, visibleFrame.maxX - popupSize.width)
            )
        }
        let y = switch side {
        case .below:
            anchorScreenRect.minY - popupSize.height
        case .above:
            anchorScreenRect.maxY
        }
        return NSPoint(x: x, y: y)
    }

    private static func availableHeight(
        for side: Side,
        anchorScreenRect: NSRect,
        visibleFrame: NSRect
    ) -> CGFloat {
        switch side {
        case .below:
            max(0, anchorScreenRect.minY - visibleFrame.minY)
        case .above:
            max(0, visibleFrame.maxY - anchorScreenRect.maxY)
        }
    }
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
    case optionsPageUnavailable
    case parentTabUnavailable
    case pinFailed
    case muteFailed
    case readerModeUnsupported

    var errorDescription: String? {
        switch self {
        case .creationFailed:
            String(
                localized: "browser.extensions.error.openTabFailed",
                defaultValue: "The extension could not open a browser tab."
            )
        case .optionsPageUnavailable:
            String(
                localized: "browser.extensions.error.optionsPageUnavailable",
                defaultValue: "This extension does not provide an options page."
            )
        case .parentTabUnavailable:
            String(
                localized: "browser.extensions.error.parentTabUnavailable",
                defaultValue: "The parent browser tab is unavailable."
            )
        case .pinFailed:
            String(
                localized: "browser.extensions.error.pinFailed",
                defaultValue: "The browser tab could not be pinned."
            )
        case .muteFailed:
            String(
                localized: "browser.extensions.error.muteFailed",
                defaultValue: "The browser tab audio setting could not be changed."
            )
        case .readerModeUnsupported:
            String(
                localized: "browser.extensions.error.readerModeUnsupported",
                defaultValue: "Reader mode is not supported in cmux browser tabs."
            )
        }
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
    case ambiguousExtensionName(String)
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
        case .ambiguousExtensionName(let name):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.extensions.diagnostics.ambiguousExtensionName",
                    defaultValue: "More than one extension is named %@. Use the extension ID instead."
                ),
                name
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
