import CmuxBrowser
import Foundation

/// Socket-worker bridges for the actor-backed Chromium pane.
///
/// The browser automation protocol is intentionally synchronous at this
/// boundary: the socket worker owns the wait, while the renderer and CDP
/// connection remain fully asynchronous and out of process. No Chromium
/// operation is ever awaited while the main actor is blocked.
extension TerminalController {
    private enum ChromiumAutomationResult: Sendable {
        case completed
        case screenshot(Data)
        case value(CDPValue)
        case command(CDPValue)
    }

    /// Three-way outcome of a socket-worker Chromium wait: the operation
    /// finished, threw, or exceeded the caller's deadline without a signal.
    private enum ChromiumAutomationOutcome {
        case success(ChromiumAutomationResult)
        case failure(any Error)
        case timedOut
    }

    private enum ChromiumAutomationOperation: Sendable {
        case evaluate(script: String, awaitPromise: Bool)
        case screenshot
        case navigate(URL)
        case back
        case forward
        case reload
        case setViewport(width: Int, height: Int)
        case command(method: String, parameters: CDPValue?)
    }

    nonisolated func v2RunChromiumJavaScript(
        browserPanel: BrowserPanel,
        script: String,
        timeout: TimeInterval
    ) -> V2JavaScriptResult {
        // `script` is built as a WebKit `callAsyncJavaScript` function body
        // and therefore contains a top-level `return`. Runtime.evaluate
        // parses a JavaScript program instead; wrap the body in an async IIFE
        // so the same envelope remains valid on both engines.
        let chromiumScript = "(async () => {\n\(script)\n})()"
        switch v2AwaitChromiumOperation(
            browserPanel: browserPanel,
            operation: .evaluate(script: chromiumScript, awaitPromise: true),
            timeout: timeout
        ) {
        case .success(.value(let value)):
            let foundationValue = value.anyValue
            guard let envelope = foundationValue as? [String: Any],
                  let type = envelope["__cmux_t"] as? String else {
                return .success(foundationValue)
            }
            switch type {
            case "undefined":
                return .success(V2BrowserUndefinedSentinel())
            case "value":
                return .success(envelope["__cmux_v"] ?? NSNull())
            default:
                return .success(foundationValue)
            }
        case .success:
            return .failure(ChromiumBrowserDiagnostic.noJavaScriptValue.message)
        case .failure(let error):
            return .failure(error.localizedDescription)
        case .timedOut:
            return .failure(ChromiumBrowserDiagnostic.javascriptTimedOut.message)
        }
    }

    nonisolated func v2CaptureChromiumScreenshot(
        browserPanel: BrowserPanel,
        timeout: TimeInterval
    ) -> Result<Data, any Error> {
        switch v2AwaitChromiumOperation(
            browserPanel: browserPanel,
            operation: .screenshot,
            timeout: timeout
        ) {
        case .success(.screenshot(let data)):
            return .success(data)
        case .success:
            return .failure(CDPError.protocolError(ChromiumBrowserDiagnostic.noScreenshot.message))
        case .failure(let error):
            return .failure(error)
        case .timedOut:
            return .failure(CDPError.disconnected(ChromiumBrowserDiagnostic.screenshotTimedOut.message))
        }
    }

    /// Sends one raw command through the pane's private page-scoped CDP
    /// connection. This is the shared seam for browser features that do not
    /// belong in the engine-neutral click/type/eval protocol (cookies and
    /// document bootstrap scripts, for example).
    nonisolated func v2RunChromiumCommand(
        browserPanel: BrowserPanel,
        method: String,
        parameters: CDPValue? = nil,
        timeout: TimeInterval = 5.0
    ) -> Result<CDPValue, any Error> {
        switch v2AwaitChromiumOperation(
            browserPanel: browserPanel,
            operation: .command(method: method, parameters: parameters),
            timeout: timeout
        ) {
        case .success(.command(let value)):
            return .success(value)
        case .success:
            return .failure(CDPError.protocolError(ChromiumBrowserDiagnostic.noCommandResult.message))
        case .failure(let error):
            return .failure(error)
        case .timedOut:
            return .failure(CDPError.disconnected(ChromiumBrowserDiagnostic.commandTimedOut.message))
        }
    }

    nonisolated func v2RegisterChromiumDocumentScript(
        browserPanel: BrowserPanel,
        source: String,
        isStyle: Bool,
        timeout: TimeInterval = 10.0
    ) -> Result<Int, any Error> {
        var registrationTask: Task<Void, Never>?
        let result: Result<Int, any Error>? = socketAwaitCallback(timeout: max(0.01, timeout)) { finish in
            registrationTask = Task { @MainActor in
                guard browserPanel.isChromiumBacked,
                      let chromium = browserPanel.browserEngineController.adapter as? (any ChromiumEngineAdapting) else {
                    finish(.failure(CDPError.notConnected))
                    return
                }
                do {
                    finish(.success(try await chromium.registerDocumentScript(source, isStyle: isStyle)))
                } catch {
                    finish(.failure(error))
                }
            }
        }
        if result == nil { registrationTask?.cancel() }
        return result ?? .failure(CDPError.disconnected(ChromiumBrowserDiagnostic.documentScriptTimedOut.message))
    }

    nonisolated func v2RunChromiumNavigation(
        browserPanel: BrowserPanel,
        operation: ChromiumNavigationOperation,
        timeout: TimeInterval = 17.5
    ) -> Result<Void, any Error> {
        let automationOperation: ChromiumAutomationOperation
        switch operation {
        case .navigate(let url): automationOperation = .navigate(url)
        case .back: automationOperation = .back
        case .forward: automationOperation = .forward
        case .reload: automationOperation = .reload
        }
        switch v2AwaitChromiumOperation(
            browserPanel: browserPanel,
            operation: automationOperation,
            timeout: timeout
        ) {
        case .success:
            return .success(())
        case .failure(let error):
            return .failure(error)
        case .timedOut:
            return .failure(CDPError.disconnected(ChromiumBrowserDiagnostic.navigationTimedOut.message))
        }
    }

    nonisolated func v2SetChromiumViewport(
        browserPanel: BrowserPanel,
        width: Int,
        height: Int,
        timeout: TimeInterval = 5.0
    ) -> Result<Void, any Error> {
        switch v2AwaitChromiumOperation(
            browserPanel: browserPanel,
            operation: .setViewport(width: width, height: height),
            timeout: timeout
        ) {
        case .success:
            return .success(())
        case .failure(let error):
            return .failure(error)
        case .timedOut:
            return .failure(CDPError.disconnected(
                String(
                    localized: "browser.viewport.error.chromiumTimedOut",
                    defaultValue: "Timed out setting Chromium viewport"
                )
            ))
        }
    }

    private nonisolated func v2AwaitChromiumOperation(
        browserPanel: BrowserPanel,
        operation: ChromiumAutomationOperation,
        timeout: TimeInterval
    ) -> ChromiumAutomationOutcome {
        var session: ChromiumBrowserSession?
        var startupReadinessTask: Task<Void, Never>?
        var cefAdapter: CEFBrowserPaneEngineAdapter?
        v2MainSync {
            guard browserPanel.isChromiumBacked else { return }
            browserPanel.startChromiumIfNeeded(initialURL: browserPanel.currentURL)
            cefAdapter = browserPanel.browserEngineController.adapter as? CEFBrowserPaneEngineAdapter
            session = browserPanel.chromiumSessionForAutomation
            startupReadinessTask = browserPanel.chromiumStartupReadinessTaskForAutomation
        }
        if let cefAdapter {
            return v2AwaitCEFOperation(
                adapter: cefAdapter,
                operation: operation,
                timeout: timeout
            )
        }
        guard let session, let startupReadinessTask else {
            return .failure(CDPError.notConnected)
        }

        var operationTask: Task<Void, Never>?
        let result: Result<ChromiumAutomationResult, any Error>? = socketAwaitCallback(
            timeout: max(0.01, timeout)
        ) { finish in
            operationTask = Task {
                do {
                    await startupReadinessTask.value
                    try Task.checkCancellation()
                    let value: ChromiumAutomationResult
                    switch operation {
                    case .evaluate(let script, let awaitPromise):
                        try await session.waitForDocumentReady()
                        value = .value(try await session.evaluateJavaScript(script, awaitPromise: awaitPromise))
                    case .screenshot:
                        value = .screenshot(try await session.screenshotPNG())
                    case .navigate(let url):
                        let revision = await session.currentNavigationRevision()
                        try await session.navigate(to: url)
                        try await session.waitForNavigation(to: nil, after: revision)
                        value = .completed
                    case .back:
                        let revision = await session.currentNavigationRevision()
                        try await session.goBack()
                        try await session.waitForNavigation(to: nil, after: revision)
                        value = .completed
                    case .forward:
                        let revision = await session.currentNavigationRevision()
                        try await session.goForward()
                        try await session.waitForNavigation(to: nil, after: revision)
                        value = .completed
                    case .reload:
                        let revision = await session.currentNavigationRevision()
                        try await session.reload()
                        try await session.waitForNavigation(to: nil, after: revision)
                        value = .completed
                    case .setViewport(let width, let height):
                        try await session.setViewport(width: width, height: height)
                        value = .completed
                    case .command(let method, let parameters):
                        value = .command(try await session.sendCommand(method: method, parameters: parameters))
                    }
                    finish(.success(value))
                } catch {
                    finish(.failure(error))
                }
            }
        }
        guard let result else {
            operationTask?.cancel()
            return .timedOut
        }
        switch result {
        case .success(let value): return .success(value)
        case .failure(let error): return .failure(error)
        }
    }

    /// CEF variant of the operation await: the browser lives in-process, so
    /// operations run on the main actor through the adapter while the socket
    /// worker owns the wait and the timeout.
    private nonisolated func v2AwaitCEFOperation(
        adapter: CEFBrowserPaneEngineAdapter,
        operation: ChromiumAutomationOperation,
        timeout: TimeInterval
    ) -> ChromiumAutomationOutcome {
        var operationTask: Task<Void, Never>?
        let result: Result<ChromiumAutomationResult, any Error>? = socketAwaitCallback(
            timeout: max(0.01, timeout)
        ) { finish in
            operationTask = Task { @MainActor in
                do {
                    try Task.checkCancellation()
                    let value: ChromiumAutomationResult
                    switch operation {
                    case .evaluate(let script, let awaitPromise):
                        value = .value(try await adapter.evaluateJavaScript(
                            script,
                            awaitPromise: awaitPromise
                        ))
                    case .screenshot:
                        value = .screenshot(try await adapter.screenshotPNG())
                    case .navigate(let url):
                        try await adapter.navigate(to: url)
                        value = .completed
                    case .back:
                        try await adapter.goBack()
                        value = .completed
                    case .forward:
                        try await adapter.goForward()
                        value = .completed
                    case .reload:
                        try await adapter.reload()
                        value = .completed
                    case .setViewport(let width, let height):
                        _ = try await adapter.sendCommand(
                            method: "Emulation.setDeviceMetricsOverride",
                            parameters: .object([
                                "width": .number(Double(width)),
                                "height": .number(Double(height)),
                                "deviceScaleFactor": .number(0),
                                "mobile": .bool(false),
                            ])
                        )
                        value = .completed
                    case .command(let method, let parameters):
                        value = .command(try await adapter.sendCommand(
                            method: method,
                            parameters: parameters
                        ))
                    }
                    finish(.success(value))
                } catch {
                    finish(.failure(error))
                }
            }
        }
        guard let result else {
            operationTask?.cancel()
            return .timedOut
        }
        switch result {
        case .success(let value): return .success(value)
        case .failure(let error): return .failure(error)
        }
    }
}

enum ChromiumNavigationOperation: Sendable {
    case navigate(URL)
    case back
    case forward
    case reload
}
