import Foundation

/// A DevTools method sent (``CEFRuntime/sendDevTools(_:method:encodedParams:)``).
struct CEFDevToolsSend: Sendable {
    /// The message whose result ``CEFRuntime/devTools(_:method:params:timeout:)`` awaits.
    let key: CEFDevToolsKey
    /// The result when Chromium answered inside the call, before any waiter existed.
    let answered: Result<String, any Error>?
}

extension CEFRuntime {
    /// Sends a one-way DevTools method now, in this turn, so an op the caller sends next reaches the page after it;
    /// nil when the page is gone. Only for a few bounded scalar parameters (a page freeze, a picture's format):
    /// they are encoded here, on the caller's actor (the main thread's CPU gate records a large one). A call whose
    /// parameters can be large, or whose result is awaited, is ``devTools(_:method:params:timeout:)``, which encodes
    /// them off the main actor.
    @discardableResult
    func sendDevTools(_ browser: Int32, method: String, params: [String: Any] = [:]) -> CEFDevToolsSend? {
        guard shim != nil else { return nil }
        return sendDevTools(browser, method: method, encodedParams: CEFDevToolsResult.params(params))
    }

    /// Sends a DevTools method whose parameters are already JSON text, now, in this turn. The one place cmux calls
    /// `cmux_shim_devtools_call`: in host mode the message id is minted by the client and its DEVTOOLS_RESULT comes
    /// in a later batch. Whoever awaits the result does so by ``CEFDevToolsSend/key``; a result nobody awaits is
    /// dropped.
    func sendDevTools(_ browser: Int32, method: String, encodedParams: String) -> CEFDevToolsSend? {
        guard let shim else { return nil }
        // Chromium answers some methods inside ExecuteDevToolsMethod, before a
        // waiter exists; without this the result was dropped and the call
        // timed out (every device emulation lost 5 s on
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
