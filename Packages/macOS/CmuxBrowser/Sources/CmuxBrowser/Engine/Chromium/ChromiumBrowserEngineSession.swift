public import AppKit
public import CmuxCore
public import Foundation
public import WebKit

/// A Chromium engine rendered through CDP screencast frames in a cmux browser pane.
@MainActor
public final class ChromiumBrowserEngineSession: BrowserEngineSession {
    /// The engine family implementing this session.
    public let kind = BrowserEngineKind.chromium

    /// The local viewport view hosted by the browser pane portal.
    public var contentView: NSView { viewportWebView }

    /// The latest Chromium state snapshot.
    public private(set) var state = BrowserEngineState()

    /// State snapshots emitted from CDP lifecycle events.
    public let stateUpdates: AsyncStream<BrowserEngineState>

    private let stateContinuation: AsyncStream<BrowserEngineState>.Continuation
    private let viewportWebView: WKWebView
    private let application: BrowserApplication?
    private let userDataDirectory: URL
    private let processController = ChromiumProcessController()
    private let viewportHandler = ChromiumViewportMessageHandler()
    var connection: CDPConnection?
    var cdpSessionID: String?
    private var startupTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var pendingRequest: URLRequest?
    private var initializationScripts: [String]
    private var initializationScriptInstallations: [Int: Task<Void, any Error>] = [:]
    var viewportWidth = 1280
    var viewportHeight = 720
    var deviceScaleFactor = 1.0
    private var isClosed = false

    /// Creates and starts a Chromium engine session.
    ///
    /// - Parameters:
    ///   - viewportWebView: The local WebKit transport view used only for canvas presentation and input capture.
    ///   - application: The installed Chromium-family browser to launch, or `nil` to show an unavailable error.
    ///   - userDataDirectory: An isolated Chrome profile directory for this engine session.
    ///   - initializationScripts: Scripts to install before the first requested page loads.
    public init(
        viewportWebView: WKWebView,
        application: BrowserApplication?,
        userDataDirectory: URL,
        initializationScripts: [String] = []
    ) {
        self.viewportWebView = viewportWebView
        self.application = application
        self.userDataDirectory = userDataDirectory
        self.initializationScripts = initializationScripts
        (stateUpdates, stateContinuation) = AsyncStream.makeStream()
        viewportHandler.session = self
        let controller = viewportWebView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "cmuxChromiumViewport")
        controller.add(viewportHandler, name: "cmuxChromiumViewport")
        let loadingText = String(localized: "browser.chromium.starting", defaultValue: "Starting Chromium…")
        let accessibilityLabel = String(
            localized: "browser.chromium.accessibility.viewport",
            defaultValue: "Chromium page"
        )
        viewportWebView.loadHTMLString(
            ChromiumViewportDocument().html(
                loadingText: loadingText,
                accessibilityLabel: accessibilityLabel
            ),
            baseURL: nil
        )
        start()
    }

    /// Queues or performs a top-level CDP navigation.
    public func load(_ request: URLRequest) {
        guard let url = request.url else { return }
        guard application != nil else {
            updateState { state in
                state.url = url
                state.isLoading = false
            }
            return
        }
        pendingRequest = request
        updateState { state in
            state.url = url
            state.isLoading = true
            state.errorMessage = nil
        }
        guard let connection, let cdpSessionID else { return }
        pendingRequest = nil
        Task { [weak self] in
            do {
                _ = try await connection.send(
                    method: "Page.navigate",
                    parameters: ["url": .string(url.absoluteString)],
                    sessionID: cdpSessionID
                )
            } catch {
                self?.presentOperationFailure()
            }
        }
    }

    /// Traverses backward in Chromium history.
    public func goBack() { traverseHistory(offset: -1) }

    /// Traverses forward in Chromium history.
    public func goForward() { traverseHistory(offset: 1) }

    /// Reloads the current Chromium page.
    public func reload() { reload(ignoreCache: false) }

    /// Reloads while bypassing Chromium's cache.
    public func reloadFromOrigin() { reload(ignoreCache: true) }

    /// Stops the current Chromium navigation.
    public func stopLoading() {
        guard let connection, let cdpSessionID else { return }
        Task { try? await connection.send(method: "Page.stopLoading", sessionID: cdpSessionID) }
        updateState { $0.isLoading = false }
    }

    /// Evaluates JavaScript through `Runtime.evaluate` and returns its by-value result.
    public func evaluateJavaScript(
        _ script: String,
        in world: BrowserJavaScriptWorld
    ) async throws -> BrowserJavaScriptValue {
        if connection == nil {
            await startupTask?.value
        }
        guard let connection, let cdpSessionID else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium is not ready.")
        }
        var parameters: [String: CDPJSONValue] = [
            "expression": .string(script),
            "awaitPromise": .bool(true),
            "returnByValue": .bool(true),
            "userGesture": .bool(true),
        ]
        if world == .isolated {
            parameters["contextId"] = .number(Double(try await isolatedExecutionContextID(
                connection: connection,
                sessionID: cdpSessionID
            )))
        }
        let response = try await connection.send(
            method: "Runtime.evaluate",
            parameters: parameters,
            sessionID: cdpSessionID
        )
        let object = response.objectValue ?? [:]
        if let exception = object["exceptionDetails"]?.objectValue {
            let text = exception["text"]?.stringValue ?? "JavaScript evaluation failed."
            throw BrowserEngineSessionError.chromiumProtocol(text)
        }
        guard let remoteObject = object["result"]?.objectValue else { return .undefined }
        if remoteObject["type"]?.stringValue == "undefined" { return .undefined }
        return remoteObject["value"]?.browserJavaScriptValue ?? .undefined
    }

    /// Installs a CDP document-start script for future navigations.
    public func addInitializationScript(_ script: String) async throws {
        let scriptIndex = initializationScripts.count
        initializationScripts.append(script)
        if connection == nil {
            await startupTask?.value
        }
        guard let connection, let cdpSessionID else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium is not ready.")
        }
        try await ensureInitializationScriptInstalled(
            at: scriptIndex,
            connection: connection,
            sessionID: cdpSessionID
        )
    }

    private func isolatedExecutionContextID(
        connection: CDPConnection,
        sessionID: String
    ) async throws -> Int {
        let frameTree = try await connection.send(method: "Page.getFrameTree", sessionID: sessionID)
        guard let frameID = frameTree.objectValue?["frameTree"]?.objectValue?["frame"]?.objectValue?["id"]?.stringValue else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium did not expose its main frame.")
        }
        let isolatedWorld = try await connection.send(
            method: "Page.createIsolatedWorld",
            parameters: [
                "frameId": .string(frameID),
                "worldName": .string("cmux.browser.automation"),
                "grantUniveralAccess": .bool(true),
            ],
            sessionID: sessionID
        )
        guard let contextID = isolatedWorld.objectValue?["executionContextId"]?.intValue else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium did not create an isolated JavaScript world.")
        }
        return contextID
    }

    /// Captures the current Chromium viewport through CDP.
    public func captureScreenshot() async throws -> Data {
        if connection == nil {
            await startupTask?.value
        }
        guard let connection, let cdpSessionID else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium is not ready.")
        }
        let response = try await connection.send(
            method: "Page.captureScreenshot",
            parameters: ["format": .string("png"), "fromSurface": .bool(true)],
            sessionID: cdpSessionID
        )
        guard let base64 = response.objectValue?["data"]?.stringValue,
              let data = Data(base64Encoded: base64) else {
            throw BrowserEngineSessionError.emptyScreenshot
        }
        return data
    }

    /// Closes the CDP target, connection, process, and local viewport bridge.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        startupTask?.cancel()
        eventTask?.cancel()
        initializationScriptInstallations.values.forEach { $0.cancel() }
        initializationScriptInstallations.removeAll()
        startupTask = nil
        eventTask = nil
        viewportWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: "cmuxChromiumViewport"
        )
        stateContinuation.finish()
        let connection = connection
        Task { [processController] in
            await processController.close()
            await connection?.close()
        }
        self.connection = nil
        cdpSessionID = nil
    }

    private func start() {
        guard let application else {
            let message = String(
                localized: "browser.chromium.error.notInstalled",
                defaultValue: "Chromium is selected, but no supported Chromium browser is installed."
            )
            presentMessage(message)
            return
        }
        updateState { $0.isLoading = true }
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let endpoint = try await processController.start(
                    application: application,
                    userDataDirectory: userDataDirectory
                )
                try await connect(to: endpoint)
            } catch is CancellationError {
                return
            } catch {
                presentLaunchFailure()
            }
        }
    }

    private func connect(to endpoint: URL) async throws {
        let connection = CDPConnection(url: endpoint)
        await connection.connect()
        self.connection = connection
        let created = try await connection.send(
            method: "Target.createTarget",
            parameters: [
                "url": .string("about:blank"),
                "width": .number(Double(viewportWidth)),
                "height": .number(Double(viewportHeight)),
            ]
        )
        guard let targetID = created.objectValue?["targetId"]?.stringValue else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium did not create a page target.")
        }
        let attached = try await connection.send(
            method: "Target.attachToTarget",
            parameters: ["targetId": .string(targetID), "flatten": .bool(true)]
        )
        guard let sessionID = attached.objectValue?["sessionId"]?.stringValue else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium did not attach to the page target.")
        }
        cdpSessionID = sessionID
        beginEvents(connection: connection, sessionID: sessionID)
        _ = try await connection.send(method: "Page.enable", sessionID: sessionID)
        _ = try await connection.send(method: "Runtime.enable", sessionID: sessionID)
        try await sendDeviceMetrics(connection: connection, sessionID: sessionID)
        _ = try await connection.send(
            method: "Page.startScreencast",
            parameters: [
                "format": .string("jpeg"),
                "quality": .number(75),
                "maxWidth": .number(Double(max(viewportWidth, 1) * 2)),
                "maxHeight": .number(Double(max(viewportHeight, 1) * 2)),
                "everyNthFrame": .number(1),
            ],
            sessionID: sessionID
        )
        try await installAllInitializationScripts(connection: connection, sessionID: sessionID)
        if let request = pendingRequest {
            load(request)
        } else {
            updateState { $0.isLoading = false }
        }
    }

    private func beginEvents(connection: CDPConnection, sessionID: String) {
        eventTask = Task { [weak self] in
            let events = await connection.events()
            for await event in events where event.sessionID == nil || event.sessionID == sessionID {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event, connection: connection, sessionID: sessionID)
            }
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            self.presentOperationFailure()
        }
    }

    private func handle(_ event: CDPEvent, connection: CDPConnection, sessionID: String) async {
        switch event.method {
        case "Page.screencastFrame":
            guard let data = event.parameters["data"]?.stringValue,
                  let frameSessionID = event.parameters["sessionId"]?.intValue else { return }
            let literal = ChromiumViewportDocumentJSONLiteral().encode("data:image/jpeg;base64,\(data)")
            _ = try? await viewportWebView.evaluateJavaScript("window.cmuxChromiumFrame(\(literal))")
            _ = try? await connection.send(
                method: "Page.screencastFrameAck",
                parameters: ["sessionId": .number(Double(frameSessionID))],
                sessionID: sessionID
            )
        case "Page.frameStartedLoading":
            updateState { $0.isLoading = true }
        case "Page.frameStoppedLoading", "Page.loadEventFired":
            updateState { $0.isLoading = false }
            await refreshDocumentState(connection: connection, sessionID: sessionID)
        case "Page.frameNavigated":
            if let frame = event.parameters["frame"]?.objectValue,
               frame["parentId"] == nil,
               let rawURL = frame["url"]?.stringValue {
                updateState { $0.url = URL(string: rawURL) }
            }
        default:
            break
        }
    }

    private func refreshDocumentState(connection: CDPConnection, sessionID: String) async {
        if case .string(let title) = try? await evaluateJavaScript("document.title") {
            updateState { $0.title = title }
        }
        guard let history = try? await connection.send(method: "Page.getNavigationHistory", sessionID: sessionID),
              let object = history.objectValue,
              let currentIndex = object["currentIndex"]?.intValue,
              let entries = object["entries"]?.arrayValue else { return }
        updateState { state in
            state.canGoBack = currentIndex > 0
            state.canGoForward = currentIndex + 1 < entries.count
        }
    }

    private func traverseHistory(offset: Int) {
        guard let connection, let cdpSessionID else { return }
        Task { [weak self] in
            do {
                let history = try await connection.send(method: "Page.getNavigationHistory", sessionID: cdpSessionID)
                guard let object = history.objectValue,
                      let currentIndex = object["currentIndex"]?.intValue,
                      let entries = object["entries"]?.arrayValue else { return }
                let targetIndex = currentIndex + offset
                guard entries.indices.contains(targetIndex),
                      let entryID = entries[targetIndex].objectValue?["id"] else { return }
                _ = try await connection.send(
                    method: "Page.navigateToHistoryEntry",
                    parameters: ["entryId": entryID],
                    sessionID: cdpSessionID
                )
            } catch {
                self?.presentOperationFailure()
            }
        }
    }

    private func reload(ignoreCache: Bool) {
        guard let connection, let cdpSessionID else { return }
        Task { [weak self] in
            do {
                _ = try await connection.send(
                    method: "Page.reload",
                    parameters: ["ignoreCache": .bool(ignoreCache)],
                    sessionID: cdpSessionID
                )
            } catch {
                self?.presentOperationFailure()
            }
        }
    }

    private func installAllInitializationScripts(
        connection: CDPConnection,
        sessionID: String
    ) async throws {
        while true {
            let scriptCount = initializationScripts.count
            for scriptIndex in 0..<scriptCount {
                try await ensureInitializationScriptInstalled(
                    at: scriptIndex,
                    connection: connection,
                    sessionID: sessionID
                )
            }
            if initializationScripts.count == scriptCount { return }
        }
    }

    private func ensureInitializationScriptInstalled(
        at scriptIndex: Int,
        connection: CDPConnection,
        sessionID: String
    ) async throws {
        if let existing = initializationScriptInstallations[scriptIndex] {
            try await existing.value
            return
        }
        let script = initializationScripts[scriptIndex]
        let installation = Task {
            _ = try await connection.send(
                method: "Page.addScriptToEvaluateOnNewDocument",
                parameters: ["source": .string(script)],
                sessionID: sessionID
            )
        }
        initializationScriptInstallations[scriptIndex] = installation
        do {
            try await installation.value
        } catch {
            initializationScriptInstallations.removeValue(forKey: scriptIndex)
            throw error
        }
    }

    private func presentLaunchFailure() {
        presentMessage(String(
            localized: "browser.chromium.error.launchFailed",
            defaultValue: "Chromium could not start. Try another installed Chromium browser or switch to WebKit."
        ))
    }

    private func presentOperationFailure() {
        presentMessage(String(
            localized: "browser.chromium.error.operationFailed",
            defaultValue: "Chromium stopped responding. Reload the page or switch to WebKit."
        ))
    }

    private func presentMessage(_ message: String) {
        updateState { state in
            state.isLoading = false
            state.errorMessage = message
        }
        let literal = ChromiumViewportDocumentJSONLiteral().encode(message)
        Task { [weak viewportWebView] in
            _ = try? await viewportWebView?.evaluateJavaScript("window.cmuxChromiumError(\(literal))")
        }
    }

    private func updateState(_ mutation: (inout BrowserEngineState) -> Void) {
        mutation(&state)
        stateContinuation.yield(state)
    }
}
