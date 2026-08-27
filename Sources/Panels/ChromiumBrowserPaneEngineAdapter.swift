import AppKit
import CmuxBrowser
import Foundation

/// Controller for one Chromium pane. It owns the child-process session and
/// the AppKit frame/input host, while BrowserPanel remains the lifecycle owner.
@MainActor
final class ChromiumBrowserPaneEngineAdapter: BrowserPaneEngineAdapter {
    let kind: BrowserEngineKind = .chromium
    let session: ChromiumBrowserSession
    let hostView: ChromiumBrowserHostView
    private var startupTask: Task<Void, Never>?
    /// The signal-driven shutdown of the previous child. A replacement waits
    /// on this task before opening a profile that may still be locked.
    private var stopTask: Task<Bool, Never>?
    private let startPrerequisite: Task<Bool, Never>?
    private var hasStarted = false
    private var initScriptSources: [String] = []
    private var styleScriptSources: [String] = []
    /// CDP registration identifiers are target-local. Sources are retained
    /// separately so a replacement child can register them again, while the
    /// identifiers let `clearDocumentScripts` remove hooks from the current
    /// target instead of merely forgetting them on the app side.
    private var initScriptIdentifiers: [String: String] = [:]
    private var styleScriptIdentifiers: [String: String] = [:]
    private var documentScriptGeneration: UInt64 = 0
    private var emulatedColorScheme: String?
    private var documentScriptRemovalTask: Task<Void, Never>?
    private var colorSchemeTask: Task<Void, Never>?
    private(set) var remoteDebuggingEndpoint: BrowserCDPEndpoint?

    var contentView: NSView? { hostView }
    var onSnapshot: ((ChromiumSessionSnapshot) -> Void)?
    var onContentFocused: (() -> Void)?
    /// Capturable, Sendable readiness signal for socket workers. Callers must
    /// obtain it on the main actor instead of retaining this AppKit adapter.
    var startupReadinessTask: Task<Void, Never>? { startupTask }

    init(
        profileID: UUID,
        storageID: UUID,
        remoteDebuggingPort: ChromiumRemoteDebuggingPort,
        environment: ChromiumBrowserRuntimeEnvironment,
        documentScripts: [(source: String, isStyle: Bool)] = [],
        startPrerequisite: Task<Bool, Never>? = nil
    ) {
        let session = ChromiumBrowserSession(
            profileID: profileID,
            storageID: storageID,
            remoteDebuggingPort: remoteDebuggingPort,
            environment: environment
        )
        self.session = session
        self.hostView = ChromiumBrowserHostView(session: session)
        self.startPrerequisite = startPrerequisite
        initScriptSources = documentScripts.filter { !$0.isStyle }.map(\.source)
        styleScriptSources = documentScripts.filter(\.isStyle).map(\.source)
        hostView.onSnapshot = { [weak self] snapshot in
            if case .crashed = snapshot.state {
                self?.hasStarted = false
            } else if case .failed = snapshot.state {
                self?.hasStarted = false
            }
            self?.remoteDebuggingEndpoint = snapshot.externallyVisibleEndpoint
            self?.onSnapshot?(snapshot)
        }
        hostView.onFocus = { [weak self] in
            self?.onContentFocused?()
        }
    }

    deinit {
        startupTask?.cancel()
        documentScriptRemovalTask?.cancel()
        colorSchemeTask?.cancel()
    }

    func start(initialURL: URL?) {
        guard !hasStarted else { return }
        hasStarted = true
        startupTask?.cancel()
        let pendingStop = stopTask
        stopTask = nil
        hostView.start()
        let startPrerequisite = self.startPrerequisite
        startupTask = Task { [weak self, startPrerequisite] in
            guard let self else { return }
            do {
                if let startPrerequisite,
                   !(await startPrerequisite.value) {
                    throw CDPError.disconnected(ChromiumBrowserDiagnostic.connectionClosed.message)
                }
                if let pendingStop {
                    await pendingStop.value
                }
                try Task.checkCancellation()
                try await session.start()
                try await installStoredDocumentScripts()
                try await applyStoredColorScheme()
                if let initialURL {
                    try await session.navigate(to: initialURL)
                }
            } catch {
                guard !(error is CancellationError) else { return }
                hasStarted = false
                remoteDebuggingEndpoint = nil
                let snapshot = ChromiumSessionSnapshot(
                    state: .failed(ChromiumBrowserDiagnostic.startupFailed.message)
                )
                await MainActor.run { [weak self] in
                    self?.onSnapshot?(snapshot)
                }
            }
        }
    }

    func stop() {
        _ = beginStop()
    }

    /// Begins signal-driven shutdown and returns a task that completes only
    /// after the child process has actually exited.
    @discardableResult
    func beginStop() -> Task<Bool, Never> {
        startupTask?.cancel()
        startupTask = nil
        documentScriptRemovalTask?.cancel()
        documentScriptRemovalTask = nil
        colorSchemeTask?.cancel()
        colorSchemeTask = nil
        hostView.stop()
        if let stopTask {
            remoteDebuggingEndpoint = nil
            hasStarted = false
            return stopTask
        }
        let task = Task { [session] in
            await session.stopAndWait()
        }
        stopTask = task
        remoteDebuggingEndpoint = nil
        hasStarted = false
        return task
    }

    @discardableResult
    func stopAndWait() async -> Bool {
        let task = beginStop()
        return await task.value
    }

    func navigate(to url: URL) async throws {
        await startupTask?.value
        try await session.navigate(to: url)
    }

    func goBack() async throws {
        await startupTask?.value
        try await session.goBack()
    }

    func goForward() async throws {
        await startupTask?.value
        try await session.goForward()
    }

    func reload() async throws {
        await startupTask?.value
        try await session.reload()
    }

    func evaluateJavaScript(_ script: String, awaitPromise: Bool) async throws -> CDPValue {
        await startupTask?.value
        try await session.waitForDocumentReady()
        return try await session.evaluateJavaScript(script, awaitPromise: awaitPromise)
    }

    func screenshotPNG() async throws -> Data {
        await startupTask?.value
        return try await session.screenshotPNG()
    }

    /// Registers a script with Chromium's document-start hook and remembers it
    /// so a renderer restart receives the same bootstrap before the restored
    /// page is navigated. The caller is responsible for evaluating style/code
    /// once in the current document when immediate application is required.
    func registerDocumentScript(_ source: String, isStyle: Bool) async throws -> Int {
        await startupTask?.value
        try await session.start()
        if isStyle, let existing = styleScriptSources.firstIndex(of: source) {
            return existing + 1
        }
        if !isStyle, let existing = initScriptSources.firstIndex(of: source) {
            return existing + 1
        }
        let generation = documentScriptGeneration
        let result = try await session.sendCommand(
            method: "Page.addScriptToEvaluateOnNewDocument",
            parameters: .object([
                "source": .string(source),
            ])
        )
        let identifier = try documentScriptIdentifier(from: result)
        guard generation == documentScriptGeneration else {
            // A clear raced the CDP round trip. Do not leave a newly-created
            // hook behind after the caller has explicitly removed scripts.
            await removeDocumentScript(identifier)
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

        // The public automation seam is synchronous at this layer, so perform
        // the protocol removals asynchronously. Errors are intentionally
        // ignored: a stopped/replaced target has already discarded its hooks.
        let session = self.session
        documentScriptRemovalTask?.cancel()
        documentScriptRemovalTask = Task {
            for identifier in identifiers {
                _ = try? await session.sendCommand(
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
        let session = self.session
        documentScriptRemovalTask = Task {
            _ = try? await session.sendCommand(
                method: "Page.removeScriptToEvaluateOnNewDocument",
                parameters: .object(["identifier": .string(identifier)])
            )
        }
    }

    /// Applies the browser theme through CDP instead of mutating the inert
    /// compatibility WKWebView. `nil` clears Chromium's emulation and lets the
    /// managed runtime use its normal system preference.
    func setEmulatedColorScheme(_ scheme: String?) {
        emulatedColorScheme = scheme
        colorSchemeTask?.cancel()
        colorSchemeTask = Task { [weak self] in
            guard let self else { return }
            do {
                await startupTask?.value
                try await applyStoredColorScheme()
            } catch is CancellationError {
                return
            } catch {
                // A theme change before the child is ready is retried by the
                // startup path; a renderer crash is reported through the
                // normal Chromium snapshot stream.
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
        _ = try await session.sendCommand(
            method: "Emulation.setEmulatedMedia",
            parameters: .object(["features": features])
        )
    }

    func documentScriptDefinitions() -> [(source: String, isStyle: Bool)] {
        initScriptSources.map { (source: $0, isStyle: false) }
            + styleScriptSources.map { (source: $0, isStyle: true) }
    }

    private func installStoredDocumentScripts() async throws {
        initScriptIdentifiers.removeAll()
        styleScriptIdentifiers.removeAll()
        let generation = documentScriptGeneration
        let sources = initScriptSources.map { (source: $0, isStyle: false) }
            + styleScriptSources.map { (source: $0, isStyle: true) }
        for entry in sources {
            let source = entry.source
            let result = try await session.sendCommand(
                method: "Page.addScriptToEvaluateOnNewDocument",
                parameters: .object([
                    "source": .string(source),
                ])
            )
            let identifier = try documentScriptIdentifier(from: result)
            guard generation == documentScriptGeneration else {
                await removeDocumentScript(identifier)
                return
            }
            if entry.isStyle {
                styleScriptIdentifiers[source] = identifier
            } else {
                initScriptIdentifiers[source] = identifier
            }
        }
    }

    private func documentScriptIdentifier(from result: CDPValue) throws -> String {
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

    private func removeDocumentScript(_ identifier: String) async {
        _ = try? await session.sendCommand(
            method: "Page.removeScriptToEvaluateOnNewDocument",
            parameters: .object(["identifier": .string(identifier)])
        )
    }
}
