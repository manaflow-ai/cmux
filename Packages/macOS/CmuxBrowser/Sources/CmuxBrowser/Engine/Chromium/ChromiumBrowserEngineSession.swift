public import AppKit
public import CmuxCore
public import Foundation
public import WebKit

/// A Chromium engine rendered through CDP screencast frames in a cmux browser pane.
@MainActor
public final class ChromiumBrowserEngineSession: BrowserEngineSession {
    /// The engine family implementing this session.
    public let kind = BrowserEngineKind.chromium

    /// The launched Chromium process used by topology and diagnostics.
    public private(set) var contentProcessIdentifier: Int32?

    /// The local viewport view hosted by the browser pane portal.
    public var contentView: NSView { viewportWebView }

    /// The page zoom factor requested from Chromium.
    public private(set) var pageZoomFactor: CGFloat = 1.0

    /// The latest Chromium state snapshot.
    public private(set) var state = BrowserEngineState()

    /// State snapshots emitted from CDP lifecycle events.
    public let stateUpdates: AsyncStream<BrowserEngineState>

    private let stateContinuation: AsyncStream<BrowserEngineState>.Continuation
    private let viewportWebView: WKWebView
    private let application: BrowserApplication?
    private let profileRuntime: ChromiumProfileRuntime
    private let viewportHandler = ChromiumViewportMessageHandler()
    private let cookieCodec = ChromiumBrowserCookieCodec()
    private let documentTitleObservation = ChromiumDocumentTitleObservation()
    var connection: CDPConnection?
    private var targetID: String?
    var cdpSessionID: String?
    private var startupTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var pendingRequest: URLRequest?
    private var initializationScripts: [String]
    private var initializationScriptInstallations: [Int: Task<Void, any Error>] = [:]
    private var appliedPageZoomFactor: CGFloat?
    private var isPageZoomReady = false
    private var pageZoomUpdateTask: Task<Void, Never>?
    private var isViewportVisible = false
    private var isScreencastActive = false
    private var screencastUpdateTask: Task<Void, Never>?
    var viewportInputQueue = ChromiumViewportInputQueue()
    var viewportInputTask: Task<Void, Never>?
    var viewportInputFailed = false
    var deviceMetricsPending = false
    var deviceMetricsTask: Task<Void, Never>?
    var viewportWidth = 1280
    var viewportHeight = 720
    var deviceScaleFactor = 1.0
    private var isClosed = false

    /// Creates and starts a Chromium engine session with an independently owned runtime.
    ///
    /// - Parameters:
    ///   - viewportWebView: The local WebKit transport view used only for canvas presentation and input capture.
    ///   - application: The installed Chromium-family browser to launch, or `nil` to show an unavailable error.
    ///   - userDataDirectory: An isolated Chrome profile directory for this engine session.
    ///   - initializationScripts: Scripts to install before the first requested page loads.
    public convenience init(
        viewportWebView: WKWebView,
        application: BrowserApplication?,
        userDataDirectory: URL,
        initializationScripts: [String] = []
    ) {
        self.init(
            viewportWebView: viewportWebView,
            profileRuntime: ChromiumProfileRuntime(
                userDataDirectory: userDataDirectory
            ),
            application: application,
            initializationScripts: initializationScripts
        )
    }

    /// Creates and starts a Chromium engine session on a profile-scoped runtime.
    ///
    /// - Parameters:
    ///   - viewportWebView: The local WebKit transport view used only for canvas presentation and input capture.
    ///   - profileRuntime: The process owner shared by every pane using the same cmux profile.
    ///   - application: The installed Chromium-family browser to launch, or `nil` to show an unavailable error.
    ///   - initializationScripts: Scripts to install before the first requested page loads.
    public init(
        viewportWebView: WKWebView,
        profileRuntime: ChromiumProfileRuntime,
        application: BrowserApplication?,
        initializationScripts: [String] = []
    ) {
        self.viewportWebView = viewportWebView
        self.application = application
        self.profileRuntime = profileRuntime
        self.initializationScripts = initializationScripts
        (stateUpdates, stateContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
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
        guard supportsNavigation(request) else {
            pendingRequest = nil
            presentMessage(BrowserEngineSessionError.unsupportedChromiumNavigationRequest.localizedDescription)
            return
        }
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

    /// Applies Chromium's native page scale without changing the canvas transport.
    public func setPageZoomFactor(_ pageZoomFactor: CGFloat) {
        guard pageZoomFactor.isFinite, pageZoomFactor > 0 else { return }
        self.pageZoomFactor = pageZoomFactor
        startPageZoomUpdateIfNeeded()
    }

    /// Starts or suspends Chromium frame delivery for the viewport's visibility.
    public func setViewportVisible(_ visible: Bool) {
        isViewportVisible = visible
        startScreencastUpdateIfNeeded()
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

    /// Reads cookies from the Chromium browser context.
    public func cookies() async throws -> [BrowserEngineCookie] {
        if connection == nil {
            await startupTask?.value
        }
        guard let connection else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium is not ready.")
        }
        let response = try await connection.send(method: "Storage.getCookies")
        return try cookieCodec.cookies(from: response)
    }

    /// Creates or replaces a cookie in the Chromium browser context.
    public func setCookie(_ cookie: BrowserEngineCookie) async throws {
        if connection == nil {
            await startupTask?.value
        }
        guard let connection, let cdpSessionID else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium is not ready.")
        }
        let response = try await connection.send(
            method: "Network.setCookie",
            parameters: cookieCodec.setParameters(for: cookie),
            sessionID: cdpSessionID
        )
        if response.objectValue?["success"] == .bool(false) {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium rejected the cookie.")
        }
    }

    /// Deletes a cookie from the Chromium browser context.
    public func deleteCookie(_ cookie: BrowserEngineCookie) async throws {
        if connection == nil {
            await startupTask?.value
        }
        guard let connection, let cdpSessionID else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium is not ready.")
        }
        _ = try await connection.send(
            method: "Network.deleteCookies",
            parameters: cookieCodec.deleteParameters(for: cookie),
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
            parameters: Self.isolatedWorldParameters(frameID: frameID),
            sessionID: sessionID
        )
        guard let contextID = isolatedWorld.objectValue?["executionContextId"]?.intValue else {
            throw BrowserEngineSessionError.chromiumProtocol("Chromium did not create an isolated JavaScript world.")
        }
        return contextID
    }

    static func isolatedWorldParameters(frameID: String) -> [String: CDPJSONValue] {
        [
            "frameId": .string(frameID),
            "worldName": .string("cmux.browser.automation"),
            "grantUniversalAccess": .bool(true),
        ]
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
        pageZoomUpdateTask?.cancel()
        pageZoomUpdateTask = nil
        appliedPageZoomFactor = nil
        isPageZoomReady = false
        screencastUpdateTask?.cancel()
        screencastUpdateTask = nil
        isViewportVisible = false
        isScreencastActive = false
        viewportInputTask?.cancel()
        viewportInputTask = nil
        viewportInputQueue.removeAll()
        viewportInputFailed = true
        contentProcessIdentifier = nil
        deviceMetricsTask?.cancel()
        deviceMetricsTask = nil
        deviceMetricsPending = false
        startupTask = nil
        eventTask = nil
        viewportWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: "cmuxChromiumViewport"
        )
        stateContinuation.finish()
        let targetID = targetID
        self.targetID = nil
        Task { [profileRuntime] in
            if let targetID {
                await profileRuntime.releaseTarget(targetID)
            }
        }
        self.connection = nil
        cdpSessionID = nil
    }

    private func start() {
        guard application != nil else {
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
                try await connect()
            } catch is CancellationError {
                return
            } catch {
                contentProcessIdentifier = nil
                presentLaunchFailure()
            }
        }
    }

    private func connect() async throws {
        guard let application else {
            throw BrowserEngineSessionError.chromiumUnavailable
        }
        let lease = try await profileRuntime.acquireTarget(
            application: application,
            width: viewportWidth,
            height: viewportHeight
        )
        do {
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
            let connection = lease.connection
            self.connection = connection
            targetID = lease.targetID
            contentProcessIdentifier = lease.processIdentifier
            let sessionID = lease.sessionID
            cdpSessionID = sessionID
            startViewportInputDrainingIfNeeded()
            beginEvents(connection: connection, sessionID: sessionID)
            _ = try await connection.send(method: "Page.enable", sessionID: sessionID)
            _ = try await connection.send(method: "Runtime.enable", sessionID: sessionID)
            try await installDocumentTitleObservation(connection: connection, sessionID: sessionID)
            let initialPageZoomFactor = pageZoomFactor
            try await sendPageZoomFactor(
                initialPageZoomFactor,
                connection: connection,
                sessionID: sessionID
            )
            appliedPageZoomFactor = initialPageZoomFactor
            isPageZoomReady = true
            startPageZoomUpdateIfNeeded()
            try await sendDeviceMetrics(connection: connection, sessionID: sessionID)
            startScreencastUpdateIfNeeded()
            try await installAllInitializationScripts(connection: connection, sessionID: sessionID)
            if let request = pendingRequest {
                load(request)
            } else {
                updateState { $0.isLoading = false }
            }
        } catch {
            self.connection = nil
            self.targetID = nil
            cdpSessionID = nil
            contentProcessIdentifier = nil
            await profileRuntime.releaseTarget(lease.targetID)
            throw error
        }
    }

    static func screencastParameters(
        viewportWidth: Int,
        viewportHeight: Int
    ) -> [String: CDPJSONValue] {
        [
            "format": .string("jpeg"),
            "quality": .number(75),
            "maxWidth": .number(Double(max(viewportWidth, 1) * 2)),
            "maxHeight": .number(Double(max(viewportHeight, 1) * 2)),
            "everyNthFrame": .number(2),
        ]
    }

    static func screencastMethod(
        isViewportVisible: Bool,
        isScreencastActive: Bool
    ) -> String? {
        guard isViewportVisible != isScreencastActive else { return nil }
        return isViewportVisible ? "Page.startScreencast" : "Page.stopScreencast"
    }

    private func startScreencastUpdateIfNeeded() {
        guard !isClosed,
              connection != nil,
              cdpSessionID != nil,
              screencastUpdateTask == nil,
              Self.screencastMethod(
                  isViewportVisible: isViewportVisible,
                  isScreencastActive: isScreencastActive
              ) != nil else {
            return
        }
        screencastUpdateTask = Task { [weak self] in
            await self?.drainScreencastUpdates()
        }
    }

    private func drainScreencastUpdates() async {
        defer { screencastUpdateTask = nil }
        while !Task.isCancelled,
              let connection,
              let cdpSessionID {
            let targetVisible = isViewportVisible
            guard let method = Self.screencastMethod(
                isViewportVisible: targetVisible,
                isScreencastActive: isScreencastActive
            ) else {
                return
            }
            let parameters = targetVisible
                ? Self.screencastParameters(
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight
                )
                : [:]
            do {
                _ = try await connection.send(
                    method: method,
                    parameters: parameters,
                    sessionID: cdpSessionID
                )
                isScreencastActive = targetVisible
            } catch is CancellationError {
                return
            } catch {
                presentOperationFailure()
                return
            }
        }
    }

    private func beginEvents(connection: CDPConnection, sessionID: String) {
        eventTask = Task { [weak self] in
            let events = await connection.events(sessionID: sessionID)
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event, connection: connection, sessionID: sessionID)
            }
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            self.presentOperationFailure()
        }
    }

    func handle(_ event: CDPEvent, connection: CDPConnection, sessionID: String) async {
        switch event.method {
        case "Page.screencastFrame":
            guard let data = event.parameters["data"]?.stringValue,
                  let frameSessionID = event.parameters["sessionId"]?.intValue else { return }
            _ = try? await viewportWebView.callAsyncJavaScript(
                "return await window.cmuxChromiumFrame('data:image/jpeg;base64,' + base64)",
                arguments: ["base64": data],
                in: nil,
                contentWorld: .page
            )
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
        case "Runtime.bindingCalled":
            guard let title = documentTitleObservation.title(from: event) else { return }
            updateState { $0.title = title }
        default:
            break
        }
    }

    private func installDocumentTitleObservation(
        connection: CDPConnection,
        sessionID: String
    ) async throws {
        _ = try await connection.send(
            method: "Runtime.addBinding",
            parameters: documentTitleObservation.bindingParameters,
            sessionID: sessionID
        )
        _ = try await connection.send(
            method: "Page.addScriptToEvaluateOnNewDocument",
            parameters: documentTitleObservation.scriptParameters,
            sessionID: sessionID
        )
    }

    private func startPageZoomUpdateIfNeeded() {
        guard isPageZoomReady,
              pageZoomUpdateTask == nil,
              appliedPageZoomFactor != pageZoomFactor,
              let connection,
              let cdpSessionID else { return }
        pageZoomUpdateTask = Task { [weak self] in
            await self?.drainPageZoomUpdates(connection: connection, sessionID: cdpSessionID)
        }
    }

    private func drainPageZoomUpdates(
        connection: CDPConnection,
        sessionID: String
    ) async {
        defer { pageZoomUpdateTask = nil }
        while !Task.isCancelled,
              self.connection === connection,
              cdpSessionID == sessionID,
              appliedPageZoomFactor != pageZoomFactor {
            let nextPageZoomFactor = pageZoomFactor
            do {
                try await sendPageZoomFactor(
                    nextPageZoomFactor,
                    connection: connection,
                    sessionID: sessionID
                )
            } catch is CancellationError {
                return
            } catch {
                presentOperationFailure()
                return
            }
            guard self.connection === connection, cdpSessionID == sessionID else { return }
            appliedPageZoomFactor = nextPageZoomFactor
        }
    }

    private func sendPageZoomFactor(
        _ pageZoomFactor: CGFloat,
        connection: CDPConnection,
        sessionID: String
    ) async throws {
        _ = try await connection.send(
            method: "Emulation.setPageScaleFactor",
            parameters: ["pageScaleFactor": .number(Double(pageZoomFactor))],
            sessionID: sessionID
        )
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

    private func supportsNavigation(_ request: URLRequest) -> Bool {
        let method = request.httpMethod ?? "GET"
        guard method.caseInsensitiveCompare("GET") == .orderedSame else { return false }
        guard request.allHTTPHeaderFields?.isEmpty != false else { return false }
        guard request.httpBody == nil, request.httpBodyStream == nil else { return false }
        return request.cachePolicy == .useProtocolCachePolicy
    }

    private func presentOperationFailure() {
        presentMessage(String(
            localized: "browser.chromium.error.operationFailed",
            defaultValue: "Chromium stopped responding. Reload the page or switch to WebKit."
        ))
    }

    func failViewportInput() {
        guard !viewportInputFailed else { return }
        viewportInputFailed = true
        viewportInputTask?.cancel()
        viewportInputTask = nil
        viewportInputQueue.removeAll()
        let targetID = targetID
        self.connection = nil
        self.targetID = nil
        cdpSessionID = nil
        contentProcessIdentifier = nil
        Task { [profileRuntime] in
            if let targetID {
                await profileRuntime.releaseTarget(targetID)
            }
        }
        presentOperationFailure()
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
