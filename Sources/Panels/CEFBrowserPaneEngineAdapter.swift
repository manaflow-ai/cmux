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
    var startupReadinessTask: Task<Void, Never>? { startupTask }

    private let profileID: UUID
    private let remoteDebuggingPort: ChromiumRemoteDebuggingPort
    private var browser: CEFBrowser?
    private var devTools: CEFDevToolsClient?
    private var eventTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var documentScriptRemovalTask: Task<Void, Never>?
    private var colorSchemeTask: Task<Void, Never>?
    private var hasStarted = false
    private var readyContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var isReady = false

    // Mirrored navigation state for snapshot synthesis.
    private var currentURL: URL?
    private var title: String?
    private var isLoading = false
    private var canGoBack = false
    private var canGoForward = false
    private var navigationRevision: UInt64 = 0

    // Document scripts mirrored so engine restarts can replay them.
    private var initScriptSources: [String] = []
    private var styleScriptSources: [String] = []
    private var initScriptIdentifiers: [String: String] = [:]
    private var styleScriptIdentifiers: [String: String] = [:]
    private var documentScriptGeneration: UInt64 = 0
    private var emulatedColorScheme: String?

    init(
        profileID: UUID,
        remoteDebuggingPort: ChromiumRemoteDebuggingPort = .disabled,
        documentScripts: [(source: String, isStyle: Bool)] = []
    ) {
        self.profileID = profileID
        self.remoteDebuggingPort = remoteDebuggingPort
        initScriptSources = documentScripts.filter { !$0.isStyle }.map(\.source)
        styleScriptSources = documentScripts.filter(\.isStyle).map(\.source)
        hostView.onFocus = { [weak self] in
            self?.onContentFocused?()
        }
    }

    deinit {
        startupTask?.cancel()
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
        startupTask = Task { @MainActor [weak self] in
            await CEFRuntimeBootstrap.waitUntilSafeToInitialize()
            guard let self, self.hasStarted, !Task.isCancelled else { return }
            do {
                try self.completeStart()
                try await self.ready()
                try await self.installStoredDocumentScripts()
                try await self.applyStoredColorScheme()
                if let initialURL {
                    try await self.navigate(to: initialURL)
                    try await self.waitForLoadCompletion()
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
            cachePath: cachePath
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
        browser?.close()
        finishStop()
    }

    /// Closes CEF and waits for its asynchronous `.closed` callback before
    /// exposing a policy/workspace transition to the rest of cmux.
    func stopAndWait() async {
        let browser = beginStopRequest()
        if let browser {
            await browser.closeAndWait()
        }
        finishStop()
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
        browser = nil
        devTools = nil
        remoteDebuggingEndpoint = nil
        hasStarted = false
        isReady = false
        publishSnapshot(state: .stopped)
    }

    func navigate(to url: URL) async throws {
        try await ready()
        let result = try await sendCommand(
            method: "Page.navigate",
            parameters: .object(["url": .string(url.absoluteString)])
        )
        if case .object(let object) = result,
           let errorText = object["errorText"]?.stringValue,
           !errorText.isEmpty {
            throw CDPError.commandFailed(errorText)
        }
        navigationRevision &+= 1
    }

    /// Awaits the end of the load cycle started by the most recent navigation
    /// command.
    ///
    /// The commit signal is a loading -> idle transition in the mirrored
    /// state. A navigation that finished before observation began (cached
    /// pages commit in milliseconds) is covered by the grace window: idle
    /// with no load observed for a short period counts as settled.
    func waitForLoadCompletion(timeout: TimeInterval = 15) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
        let quietGraceDeadline = clock.now + .milliseconds(1500)
        var sawLoading = false
        while clock.now < deadline {
            if isLoading {
                sawLoading = true
            } else if sawLoading || clock.now >= quietGraceDeadline {
                return
            }
            try await clock.sleep(for: .milliseconds(50))
        }
        throw ChromiumBrowserDiagnostic.navigationTimedOut
    }

    func goBack() async throws {
        try await ready()
        browser?.goBack()
    }

    func goForward() async throws {
        try await ready()
        browser?.goForward()
    }

    func reload() async throws {
        try await ready()
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
                    }
                }
            },
            onCancel: {
                Task { @MainActor [weak self] in
                    guard let continuation = self?.readyContinuations.removeValue(forKey: waiterID) else {
                        return
                    }
                    continuation.resume(throwing: CancellationError())
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
        onSnapshot?(snapshot)
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
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
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
