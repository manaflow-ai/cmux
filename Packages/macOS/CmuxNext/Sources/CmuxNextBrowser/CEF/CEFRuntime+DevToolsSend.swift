import Foundation

/// A DevTools method sent in the caller's turn (``CEFRuntime/sendDevTools(_:method:params:)``).
struct CEFDevToolsSend {
    /// The message whose result ``CEFRuntime/devTools(_:method:params:timeout:)`` awaits.
    let key: CEFDevToolsKey
    /// The result when Chromium answered inside the call, before any waiter existed.
    let answered: Result<String, any Error>?
}

extension CEFRuntime {
    /// Sends a DevTools method now, in this turn, so an op the caller sends next reaches the page
    /// after it; nil when the page is gone. The one place cmux calls `cmux_shim_devtools_call`: in
    /// host mode the message id is minted by the client and its
    /// DEVTOOLS_RESULT comes in a later batch. Whoever awaits the result does so by ``CEFDevToolsSend/key``;
    /// a result nobody awaits is dropped.
    @discardableResult
    func sendDevTools(_ browser: Int32, method: String, params: [String: Any] = [:]) -> CEFDevToolsSend? {
        guard let shim else { return nil }
        // Chromium answers some methods inside ExecuteDevToolsMethod, before a
        // waiter exists; without this the result was dropped and the call
        // timed out (every device emulation lost 5 s on
        // Emulation.setEmitTouchEventsForMouse).
        // A nested run loop inside the call may start another call: keep the outer one's table.
        let outer = synchronousDevToolsResults
        synchronousDevToolsResults = [:]
        let message = shim.devToolsCall(browser, method, CEFDevToolsResult.params(params))
        let answered = synchronousDevToolsResults
        synchronousDevToolsResults = outer.map { $0.merging(answered ?? [:]) { first, _ in first } }
        guard message != 0 else { return nil }
        let key = CEFDevToolsKey(browser: browser, message: message)
        return CEFDevToolsSend(key: key, answered: answered?[key])
    }
}
