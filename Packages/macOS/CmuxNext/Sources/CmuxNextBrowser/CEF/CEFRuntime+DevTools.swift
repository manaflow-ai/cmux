import Foundation

/// A DevTools method sent to Chromium (``CEFRuntime/sendDevTools(_:method:encodedParams:)``).
struct CEFDevToolsSend {
    /// The message whose result the caller awaits.
    let key: CEFDevToolsKey
    /// The result when Chromium answered inside the call, before any waiter existed.
    let answered: Result<String, any Error>?
}

/// A DevTools call's parameters: JSON text made in the caller's turn, or values to encode off the main actor.
private enum CEFDevToolsParams {
    case encoded(String)
    case large([String: any Sendable])
}

extension CEFRuntime {
    /// Longest wait for an in-process DevTools result.
    static let devToolsTimeout: Duration = .seconds(5)

    /// Runs a DevTools method in process and returns its JSON result, or throws `timedOut` when no result arrives
    /// within `timeout`. For cmux's own small parameters (a few values, a document script): they are encoded in the
    /// caller's turn. Parameters a page or an agent can make large go through ``devTools(_:method:payload:timeout:)``.
    func devTools(_ browser: Int32, method: String, params: [String: Any] = [:],
                  timeout: Duration = CEFRuntime.devToolsTimeout) async throws -> String {
        try await devTools(browser, method: method, .encoded(CEFDevToolsResult.params(params)), timeout: timeout)
    }

    /// Runs a DevTools method whose parameters may be megabytes (an app page's script batch, an agent's script):
    /// large ones (``CEFDevToolsResult/isLarge(_:)``) are encoded off the main actor, and the call still reaches
    /// Chromium in its browser's call order (``CEFDevToolsCallOrder``).
    func devTools(_ browser: Int32, method: String, payload: [String: any Sendable],
                  timeout: Duration = CEFRuntime.devToolsTimeout) async throws -> String {
        let params: CEFDevToolsParams = CEFDevToolsResult.isLarge(payload) ? .large(payload) : .encoded(CEFDevToolsResult.params(payload))
        return try await devTools(browser, method: method, params, timeout: timeout)
    }

    private func devTools(_ browser: Int32, method: String, _ params: CEFDevToolsParams, timeout: Duration) async throws -> String {
        guard shim != nil else { throw BrowserTabError.closed }
        let sent: CEFDevToolsSend?
        if case .encoded(let text) = params, devToolsOrder.isIdle(browser) {
            // Nothing of this browser waits: sent in this turn, as an op the caller makes next expects.
            sent = sendDevTools(browser, method: method, encodedParams: text)
        } else {
            let ticket = devToolsOrder.take(browser)
            let text: String
            switch params {
            case .encoded(let encoded): text = encoded
            case .large(let values): text = await CEFDevToolsResult.encodedParams(values)
            }
            await devToolsOrder.turn(ticket, of: browser)
            sent = sendDevTools(browser, method: method, encodedParams: text)
            devToolsOrder.leave(ticket, of: browser)
        }
        guard let sent else { throw BrowserTabError.closed }
        if let answered = sent.answered { return try answered.get() }
        return try await devToolsCalls.reply(for: sent.key, timeout: timeout) {
            BrowserTabError.timedOut("DevTools \(method) (\(timeout))")
        }
    }

    /// A one-way DevTools method (a freeze) in `browser`'s call order: sent now when no call of `browser` waits,
    /// else right after the last one; nobody waits for its result. For a few scalar parameters only: they are
    /// encoded in the caller's turn.
    ///
    /// - Returns: False when it was sent now and Chromium refused it (the page is gone); true when it was sent,
    ///   or waits its turn.
    @discardableResult
    func postDevTools(_ browser: Int32, method: String, params: [String: Any]) -> Bool {
        let text = CEFDevToolsResult.params(params)
        return devToolsOrder.post(browser) { [weak self] in
            self?.sendDevTools(browser, method: method, encodedParams: text) != nil
        }
    }

    /// Sends a DevTools method whose parameters are JSON text, now, in this turn: only from the paths above, so
    /// every call keeps its browser's order. Nil when the browser is gone.
    private func sendDevTools(_ browser: Int32, method: String, encodedParams: String) -> CEFDevToolsSend? {
        guard let shim else { return nil }
        // Chromium answers some methods inside the shim call (SendDevToolsMessage), before a
        // waiter exists; without this the result was dropped and the call
        // timed out after `timeout` (every device emulation lost 5 s on
        // Emulation.setEmitTouchEventsForMouse).
        // A nested run loop inside the call may start another call: keep the outer one's table.
        let outer = synchronousDevToolsResults
        synchronousDevToolsResults = [:]
        let message = shim.devToolsCall(browser, method, encodedParams)
        let answered = synchronousDevToolsResults
        synchronousDevToolsResults = outer.map { $0.merging(answered ?? [:]) { first, _ in first } }
        guard message != 0 else { return nil }
        let key = CEFDevToolsKey(browser: browser, message: message)
        return CEFDevToolsSend(key: key, answered: answered?[key])
    }
}
