import AppKit
import CmuxBrowser
import CmuxCEF
import Foundation

/// Controller for one CEF-backed Chromium pane.
///
/// Rendering is native: the CEF browser draws into its own GPU-composited
/// window adopted over the pane rect, so there is no frame streaming and no
/// CDP input bridge. Automation still speaks the DevTools protocol through
/// CEF's in-process seam, which keeps every existing browser verb working.
@MainActor
final class CEFBrowserPaneEngineAdapter: BrowserPaneEngineAdapter {
    let kind: BrowserEngineKind = .chromium
    let hostView = CEFBrowserHostView()
    private(set) var remoteDebuggingEndpoint: BrowserCDPEndpoint?

    var contentView: NSView? { hostView }
    /// The CEF-owned child window, once browser creation has completed.
    var browserWindow: NSWindow? { browser?.nsWindow }
    /// Whether the child window is adopted over a visible pane.
    var isBrowserWindowFocusReady: Bool { hostView.isFocusReady }
    var onSnapshot: ((ChromiumSessionSnapshot) -> Void)?
    var onContentFocused: (() -> Void)?
    /// Called when the embedded CEF runtime cannot start; the owning
    /// controller may replace this adapter with the streamed fallback.
    var onStartupFailure: (() -> Void)?
    var startupReadinessTask: Task<Void, Never>? { startupTask }

    private let profileID: UUID
    private let storageID: UUID
    private let remoteDebuggingPort: ChromiumRemoteDebuggingPort
    private let startPrerequisite: Task<Bool, Never>?
    private let navigationPolicy: ((URL) -> Bool)?
    private var browser: CEFBrowser?
    private var devTools: CEFDevToolsClient?
    private var eventTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var stopCompletionTask: Task<Void, Never>?
    private var documentScriptRemovalTask: Task<Void, Never>?
    private var colorSchemeTask: Task<Void, Never>?
    private var hasStarted = false
    private var readyContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var readyTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var isReady = false
    private static let readyDeadline: Duration = .seconds(15)

    // Mirrored navigation state for snapshot synthesis.
    private var currentURL: URL?
    private var title: String?
    private var isLoading = false
    private var canGoBack = false
    private var canGoForward = false
    private var navigationRevision: UInt64 = 0
    private var snapshotContinuations: [UUID: AsyncStream<ChromiumSessionSnapshot>.Continuation] = [:]

    // Document scripts mirrored so engine restarts can replay them.
    private var initScriptSources: [String] = []
    private var styleScriptSources: [String] = []
    private var initScriptIdentifiers: [String: String] = [:]
    private var styleScriptIdentifiers: [String: String] = [:]
    private var documentScriptGeneration: UInt64 = 0
    private var emulatedColorScheme: String?

    init(
        profileID: UUID,
        storageID: UUID = UUID(),
        remoteDebuggingPort: ChromiumRemoteDebuggingPort = .disabled,
        documentScripts: [(source: String, isStyle: Bool)] = [],
        startPrerequisite: Task<Bool, Never>? = nil,
        navigationPolicy: ((URL) -> Bool)? = nil
    ) {
        self.profileID = profileID
        self.storageID = storageID
        self.remoteDebuggingPort = remoteDebuggingPort
        self.startPrerequisite = startPrerequisite
        self.navigationPolicy = navigationPolicy
        initScriptSources = documentScripts.filter { !$0.isStyle }.map(\.source)
        styleScriptSources = documentScripts.filter(\.isStyle).map(\.source)
        hostView.onFocus = { [weak self] in
            self?.onContentFocused?()
        }
    }

    deinit {
        startupTask?.cancel()
        stopCompletionTask?.cancel()
        documentScriptRemovalTask?.cancel()
        colorSchemeTask?.cancel()
        // The lifecycle owner requests `close()` while isolated to the main
        // actor. Swift deinitializers are nonisolated, so no AppKit/CEF call
        // can be made safely from this finalizer.
    }

    func start(initialURL: URL?) {
        guard !hasStarted else { return }
        hasStarted = true
        publishSnapshot(state: .starting)
        startupTask?.cancel()
        let startPrerequisite = self.startPrerequisite
        startupTask = Task { @MainActor [weak self, startPrerequisite] in
            guard let self, self.hasStarted, !Task.isCancelled else { return }
            do {
                if let startPrerequisite,
                   !(await startPrerequisite.value) {
                    throw CDPError.disconnected(ChromiumBrowserDiagnostic.connectionClosed.message)
                }
                await CEFRuntimeBootstrap.waitUntilSafeToInitialize()
                guard self.hasStarted, !Task.isCancelled else { return }
                do {
                    try self.completeStart()
                } catch {
                    self.cleanupAfterStartupFailure()
                    self.publishFailure(ChromiumBrowserDiagnostic.startupFailed.message)
                    self.onStartupFailure?()
                    return
                }
                try await self.ready()
                try await self.installStoredDocumentScripts()
                try await self.applyStoredColorScheme()
                if let initialURL {
                    let revision = self.currentNavigationRevision()
                    try await self.navigate(to: initialURL)
                    try await self.waitForNavigation(to: initialURL, after: revision)
                }
            } catch is CancellationError {
                return
            } catch {
                self.cleanupAfterStartupFailure()
                self.publishFailure(ChromiumBrowserDiagnostic.startupFailed.message)
            }
        }
    }

    private func completeStart() throws {
        guard CEFRuntimeBootstrap.initializeIfNeeded() else {
            throw CDPError.notConnected
        }
        // CEF captures the port during process-wide initialization. A later
        // pane or settings change cannot move that listener, so publish only
        // the port CEF actually owns.
        if remoteDebuggingPort.isExternallyAttachable,
           let activePort = CEFRuntime.activeRemoteDebuggingPort {
            remoteDebuggingEndpoint = BrowserCDPEndpoint(port: activePort)
        } else {
            remoteDebuggingEndpoint = nil
        }
        // The default profile uses CEF's global request context: command-line
        // extensions (--load-extension) only attach there, matching Chrome's
        // per-profile extension model. Named profiles get isolated contexts.
        let isDefaultProfile = profileID == BrowserProfileRepository.builtInDefaultProfileID
        let cachePath = isDefaultProfile
            ? nil
            : CEFRuntimeBootstrap.profileCachePath(for: profileID)
        guard let browser = CEFBrowser.create(
            url: URL(string: "about:blank")!,
            cachePath: cachePath,
            shouldBlockNavigation: navigationPolicy
        ) else {
            remoteDebuggingEndpoint = nil
            throw CDPError.notConnected
        }
        self.browser = browser
        self.devTools = CEFDevToolsClient(browser: browser)
        currentURL = nil
        let events = browser.events()
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    func stop() {
        let browser = beginStopRequest()
        guard let browser else {
            finishStop()
            return
        }
        stopCompletionTask?.cancel()
        stopCompletionTask = Task { @MainActor [weak self, browser] in
            let didClose = await browser.closeAndWait()
            guard let self else { return }
            if didClose {
                self.finishStop()
            } else {
                self.publishFailure(ChromiumBrowserDiagnostic.operationEnded.message)
            }
        }
    }

    /// Closes CEF and waits for its asynchronous `.closed` callback before
    /// exposing a policy/workspace transition to the rest of cmux.
    @discardableResult
    func stopAndWait() async -> Bool {
        stopCompletionTask?.cancel()
        stopCompletionTask = nil
        let browser = beginStopRequest()
        guard let browser else {
            finishStop()
            return true
        }
        let didClose = await browser.closeAndWait()
        if didClose {
            finishStop()
        } else {
            publishFailure(ChromiumBrowserDiagnostic.operationEnded.message)
        }
        return didClose
    }

    private func beginStopRequest() -> CEFBrowser? {
        startupTask?.cancel()
        startupTask = nil
        documentScriptRemovalTask?.cancel()
        documentScriptRemovalTask = nil
        colorSchemeTask?.cancel()
        colorSchemeTask = nil
        eventTask?.cancel()
        eventTask = nil
        cancelReadyWaiters()
        hostView.detach()
        browser?.stopLoading()
        return browser
    }

    private func finishStop() {
        stopCompletionTask = nil
        browser = nil
        devTools = nil
        remoteDebuggingEndpoint = nil
        hasStarted = false
        isReady = false
        publishSnapshot(state: .stopped)
    }

    func navigate(to url: URL) async throws {
        try await ready()
        beginNavigation()
        let result: CDPValue
        do {
            result = try await sendCommand(
                method: "Page.navigate",
                parameters: .object(["url": .string(url.absoluteString)])
            )
        } catch {
            isLoading = false
            publishSnapshot(state: .running(nil))
            throw error
        }
        if case .object(let object) = result,
           let errorText = object["errorText"]?.stringValue,
           !errorText.isEmpty {
            isLoading = false
            publishSnapshot(state: .running(nil))
            throw CDPError.commandFailed(errorText)
        }
    }

    /// Returns the current main-frame navigation revision.
    ///
    /// Callers capture this value immediately before issuing a navigation and
    /// pass it to ``waitForNavigation(to:after:)`` so a superseded load cannot
    /// satisfy the wrong operation.
    func currentNavigationRevision() -> UInt64 {
        navigationRevision
    }

    /// Awaits a specific main-frame navigation using the adapter's event stream.
    ///
    /// A target URL, when supplied, must match the committed main-frame URL;
    /// redirects are represented by the final address event. The bounded
    /// timeout is a genuine operation deadline, not a polling interval.
    ///
    /// - Parameters:
    ///   - targetURL: Optional destination that must match the completed page.
    ///   - revision: Revision captured before issuing the navigation command.
    ///   - timeout: Maximum wait in seconds.
    func waitForNavigation(
        to targetURL: URL?,
        after revision: UInt64,
        timeout: TimeInterval = 15
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw ChromiumBrowserDiagnostic.navigationStreamEnded
                }
                try await self.awaitNavigation(to: targetURL, after: revision)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0.001, timeout)))
                throw ChromiumBrowserDiagnostic.navigationTimedOut
            }
            defer { group.cancelAll() }
            try await group.next()!
        }
    }

    /// Compatibility wrapper for older call sites. New automation paths use
    /// ``waitForNavigation(to:after:)`` with a revision and target URL.
    func waitForLoadCompletion(timeout: TimeInterval = 15) async throws {
        let revision = navigationRevision > 0 ? navigationRevision - 1 : 0
        try await waitForNavigation(to: nil, after: revision, timeout: timeout)
    }

    func goBack() async throws {
        try await ready()
        beginNavigation()
        browser?.goBack()
    }

    func goForward() async throws {
        try await ready()
        beginNavigation()
        browser?.goForward()
    }

    func reload() async throws {
        try await ready()
        beginNavigation()
        browser?.reload()
    }

    func evaluateJavaScript(_ script: String, awaitPromise: Bool) async throws -> CDPValue {
        try await ready()
        let result = try await sendCommand(
            method: "Runtime.evaluate",
            parameters: .object([
                "expression": .string(script),
                "awaitPromise": .bool(awaitPromise),
                "returnByValue": .bool(true),
            ])
        )
        guard case .object(let object) = result else { return .null }
        if case .object(let exception)? = object["exceptionDetails"] {
            let text = exception["exception"].flatMap { value -> String? in
                guard case .object(let details) = value else { return nil }
                return details["description"]?.stringValue
            } ?? exception["text"]?.stringValue ?? "JavaScript exception"
            throw CDPError.commandFailed(text)
        }
        guard case .object(let evaluation)? = object["result"] else { return .null }
        return evaluation["value"] ?? .null
    }

    func screenshotPNG() async throws -> Data {
        try await ready()
        let result = try await sendCommand(
            method: "Page.captureScreenshot",
            parameters: .object(["format": .string("png")])
        )
        guard case .object(let object) = result,
              let encoded = object["data"]?.stringValue,
              let data = Data(base64Encoded: encoded) else {
            throw CDPError.protocolError(ChromiumBrowserDiagnostic.noScreenshot.message)
        }
        return data
    }

    /// Sends one raw DevTools command; the seam shared by cookies, storage,
    /// viewport emulation, and the other engine-neutral automation verbs.
    func sendCommand(method: String, parameters: CDPValue? = nil) async throws -> CDPValue {
        guard let devTools else { throw CDPError.notConnected }
        var params: [String: Any] = [:]
        if let parameters {
            let data = try JSONEncoder().encode(parameters)
            params = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        let resultData: Data
        do {
            resultData = try await devTools.send(method: method, params: params)
        } catch CEFDevToolsClient.ClientError.timedOut {
            throw ChromiumBrowserDiagnostic.commandTimedOut
        }
        return (try? JSONDecoder().decode(CDPValue.self, from: resultData)) ?? .null
    }

    /// Awaits browser readiness (creation completed) before automation runs.
    func ready() async throws {
        guard browser != nil else { throw CDPError.notConnected }
        if isReady { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if isReady {
                        continuation.resume(returning: ())
                    } else {
                        readyContinuations[waiterID] = continuation
                        readyTimeoutTasks[waiterID] = Task { @MainActor [weak self] in
                            do {
                                try await Task.sleep(for: Self.readyDeadline)
                            } catch {
                                return
                            }
                            self?.finishReadyWaiter(
                                waiterID,
                                error: ChromiumBrowserDiagnostic.startupTimedOut
                            )
                        }
                    }
                }
            },
            onCancel: {
                Task { @MainActor [weak self] in
                    self?.finishReadyWaiter(waiterID, error: CancellationError())
                }
            }
        )
    }

    func registerDocumentScript(_ source: String, isStyle: Bool) async throws -> Int {
        try await ready()
        if isStyle, let existing = styleScriptSources.firstIndex(of: source) {
            return existing + 1
        }
        if !isStyle, let existing = initScriptSources.firstIndex(of: source) {
            return existing + 1
        }
        let generation = documentScriptGeneration
        let result = try await sendCommand(
            method: "Page.addScriptToEvaluateOnNewDocument",
            parameters: .object(["source": .string(source)])
        )
        let identifier = try Self.documentScriptIdentifier(from: result)
        guard generation == documentScriptGeneration else {
            _ = try? await sendCommand(
                method: "Page.removeScriptToEvaluateOnNewDocument",
                parameters: .object(["identifier": .string(identifier)])
            )
            throw CancellationError()
        }
        if isStyle {
            styleScriptSources.append(source)
            styleScriptIdentifiers[source] = identifier
            return styleScriptSources.count
        }
        initScriptSources.append(source)
        initScriptIdentifiers[source] = identifier
        return initScriptSources.count
    }

    func clearDocumentScripts() {
        documentScriptGeneration &+= 1
        let identifiers = Array(initScriptIdentifiers.values)
            + Array(styleScriptIdentifiers.values)
        initScriptSources.removeAll()
        styleScriptSources.removeAll()
        initScriptIdentifiers.removeAll()
        styleScriptIdentifiers.removeAll()
        guard !identifiers.isEmpty else { return }
        documentScriptRemovalTask?.cancel()
        documentScriptRemovalTask = Task { [weak self] in
            for identifier in identifiers {
                _ = try? await self?.sendCommand(
                    method: "Page.removeScriptToEvaluateOnNewDocument",
                    parameters: .object(["identifier": .string(identifier)])
                )
            }
        }
    }

    func removeDocumentScript(_ source: String, isStyle: Bool) {
        documentScriptGeneration &+= 1
        let identifier: String?
        if isStyle {
            styleScriptSources.removeAll { $0 == source }
            identifier = styleScriptIdentifiers.removeValue(forKey: source)
        } else {
            initScriptSources.removeAll { $0 == source }
            identifier = initScriptIdentifiers.removeValue(forKey: source)
        }
        guard let identifier else { return }
        documentScriptRemovalTask?.cancel()
        documentScriptRemovalTask = Task { [weak self] in
            _ = try? await self?.sendCommand(
                method: "Page.removeScriptToEvaluateOnNewDocument",
                parameters: .object(["identifier": .string(identifier)])
            )
        }
    }

    func stopLoadingPage() {
        browser?.stopLoading()
        isLoading = false
    }

    func documentScriptDefinitions() -> [(source: String, isStyle: Bool)] {
        initScriptSources.map { (source: $0, isStyle: false) }
            + styleScriptSources.map { (source: $0, isStyle: true) }
    }

    func setEmulatedColorScheme(_ scheme: String?) {
        emulatedColorScheme = scheme
        colorSchemeTask?.cancel()
        colorSchemeTask = Task { [weak self] in
            try? await self?.applyStoredColorScheme()
        }
    }

    private func snapshots() -> AsyncStream<ChromiumSessionSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            snapshotContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.snapshotContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func awaitNavigation(to targetURL: URL?, after revision: UInt64) async throws {
        if isNavigationComplete(to: targetURL, after: revision) {
            return
        }
        let stream = snapshots()
        for await snapshot in stream {
            try Task.checkCancellation()
            switch snapshot.state {
            case .crashed(let status):
                throw CDPError.disconnected(
                    ChromiumBrowserDiagnostic.rendererExited(status).message
                )
            case .failed(let message):
                throw CDPError.commandFailed(message)
            default:
                break
            }
            guard snapshot.navigationRevision > revision,
                  !snapshot.isLoading else { continue }
            if let targetURL {
                guard Self.matches(url: snapshot.currentURL, target: targetURL) else { continue }
            }
            return
        }
        throw ChromiumBrowserDiagnostic.navigationStreamEnded
    }

    private func isNavigationComplete(to targetURL: URL?, after revision: UInt64) -> Bool {
        guard navigationRevision > revision, !isLoading else { return false }
        guard let targetURL else { return true }
        return Self.matches(url: currentURL, target: targetURL)
    }

    private static func matches(url: URL?, target: URL) -> Bool {
        guard let url else { return false }
        return url.absoluteString == target.absoluteString ||
            (url.scheme == target.scheme && url.host == target.host &&
             url.path == target.path && url.query == target.query)
    }

    // MARK: - Event handling

    private func handle(_ event: CEFBrowser.Event) {
        switch event {
        case .created:
            isReady = true
            if let cefWindow = browser?.nsWindow {
                hostView.attach(cefWindow: cefWindow)
            }
            publishSnapshot(state: .running(nil))
            let waiters = readyContinuations.values
            readyContinuations.removeAll()
            for task in readyTimeoutTasks.values { task.cancel() }
            readyTimeoutTasks.removeAll()
            for waiter in waiters { waiter.resume(returning: ()) }
        case .titleChanged(let value):
            title = value
            publishSnapshot(state: .running(nil))
        case .addressChanged(let value):
            currentURL = URL(string: value)
            navigationRevision &+= 1
            publishSnapshot(state: .running(nil))
        case .loadingStateChanged(let loading, let back, let forward):
            isLoading = loading
            canGoBack = back
            canGoForward = forward
            publishSnapshot(state: .running(nil))
        case .rendererCrashed:
            isReady = false
            hasStarted = false
            startupTask?.cancel()
            startupTask = nil
            eventTask?.cancel()
            eventTask = nil
            cancelReadyWaiters()
            hostView.detach()
            remoteDebuggingEndpoint = nil
            browser?.close()
            browser = nil
            devTools = nil
            publishSnapshot(state: .crashed(1))
            finishSnapshotStreams()
        case .closed:
            isReady = false
            hasStarted = false
            startupTask?.cancel()
            startupTask = nil
            documentScriptRemovalTask?.cancel()
            documentScriptRemovalTask = nil
            colorSchemeTask?.cancel()
            colorSchemeTask = nil
            remoteDebuggingEndpoint = nil
            hostView.detach()
            browser = nil
            devTools = nil
            eventTask = nil
            let waiters = readyContinuations.values
            readyContinuations.removeAll()
            for waiter in waiters {
                waiter.resume(throwing: CDPError.notConnected)
            }
            publishSnapshot(state: .stopped)
            finishSnapshotStreams()
        }
    }

    private func publishSnapshot(state: ChromiumSessionState) {
        let snapshot = ChromiumSessionSnapshot(
            state: state,
            currentURL: currentURL,
            title: title,
            externallyVisibleEndpoint: remoteDebuggingEndpoint,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            isLoading: isLoading,
            navigationRevision: navigationRevision
        )
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
        onSnapshot?(snapshot)
    }

    private func beginNavigation() {
        navigationRevision &+= 1
        isLoading = true
        publishSnapshot(state: .running(nil))
    }

    private func finishSnapshotStreams() {
        for continuation in snapshotContinuations.values {
            continuation.finish()
        }
        snapshotContinuations.removeAll()
    }

    private func publishFailure(_ message: String) {
        onSnapshot?(ChromiumSessionSnapshot(state: .failed(message)))
    }

    /// Releases a partially-created CEF browser before exposing startup
    /// failure. CEF may have created its native window before a later bootstrap
    /// command fails, so leaving the handle alive would leak a hidden child and
    /// make a subsequent retry create a second browser for the same pane.
    private func cleanupAfterStartupFailure() {
        eventTask?.cancel()
        eventTask = nil
        documentScriptRemovalTask?.cancel()
        documentScriptRemovalTask = nil
        colorSchemeTask?.cancel()
        colorSchemeTask = nil
        cancelReadyWaiters()
        hostView.detach()
        browser?.close()
        browser = nil
        devTools = nil
        remoteDebuggingEndpoint = nil
        hasStarted = false
        isReady = false
    }

    private func cancelReadyWaiters() {
        let waiters = readyContinuations.values
        readyContinuations.removeAll()
        for task in readyTimeoutTasks.values { task.cancel() }
        readyTimeoutTasks.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
    }

    private func finishReadyWaiter(_ waiterID: UUID, error: (any Error)? = nil) {
        guard let waiter = readyContinuations.removeValue(forKey: waiterID) else { return }
        readyTimeoutTasks.removeValue(forKey: waiterID)?.cancel()
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume(returning: ())
        }
    }

    private func installStoredDocumentScripts() async throws {
        initScriptIdentifiers.removeAll()
        styleScriptIdentifiers.removeAll()
        let generation = documentScriptGeneration
        let entries = documentScriptDefinitions()
        for entry in entries {
            let result = try await sendCommand(
                method: "Page.addScriptToEvaluateOnNewDocument",
                parameters: .object(["source": .string(entry.source)])
            )
            let identifier = try Self.documentScriptIdentifier(from: result)
            guard generation == documentScriptGeneration else { return }
            if entry.isStyle {
                styleScriptIdentifiers[entry.source] = identifier
            } else {
                initScriptIdentifiers[entry.source] = identifier
            }
        }
    }

    private func applyStoredColorScheme() async throws {
        let features: CDPValue = emulatedColorScheme.map { scheme in
            .array([.object([
                "name": .string("prefers-color-scheme"),
                "value": .string(scheme),
            ])])
        } ?? .array([])
        _ = try await sendCommand(
            method: "Emulation.setEmulatedMedia",
            parameters: .object(["features": features])
        )
    }

    private static func documentScriptIdentifier(from result: CDPValue) throws -> String {
        guard case .object(let object) = result,
              let rawIdentifier = object["identifier"] else {
            throw CDPError.protocolError(
                ChromiumBrowserDiagnostic.malformedDocumentScriptRegistration.message
            )
        }
        if let identifier = rawIdentifier.stringValue { return identifier }
        if let number = rawIdentifier.doubleValue { return String(number) }
        throw CDPError.protocolError(
            ChromiumBrowserDiagnostic.malformedDocumentScriptRegistration.message
        )
    }
}
