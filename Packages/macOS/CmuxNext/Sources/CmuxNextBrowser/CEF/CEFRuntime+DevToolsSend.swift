import Foundation

/// The answer of a DevTools call sent in its browser's order (``CEFRuntime/sendDevToolsInOrder(_:method:params:timeout:refused:mayPost:)``).
struct CEFDevToolsAnswer: Sendable {
    /// Awaits the method's JSON result.
    let value: @MainActor @Sendable () async throws -> String
}

/// A DevTools method sent (``CEFRuntime/sendDevTools(_:method:encodedParams:)``).
struct CEFDevToolsSend: Sendable {
    /// The message whose result ``CEFRuntime/devTools(_:method:params:timeout:)`` awaits.
    let key: CEFDevToolsKey
    /// The result when Chromium answered inside the call, before any waiter existed.
    let answered: Result<String, any Error>?
}

extension CEFRuntime {
    /// A one-way DevTools method in `browser`'s order (``CEFDevToolsSendOrder/post(_:_:)``): sent now, in this turn,
    /// when no earlier call of `browser` waits, else right after the last one. Only for a few bounded scalar
    /// parameters (a page freeze): they are encoded on the caller's actor (the main thread's CPU gate records a large
    /// one).
    ///
    /// - Returns: False when it was sent now and Chromium refused it (the page is gone); true when it was sent, or
    ///   waits its turn behind an earlier call.
    @discardableResult
    func postDevTools(_ browser: Int32, method: String, params: [String: Any] = [:]) -> Bool {
        guard shim != nil else { return false }
        let encoded = CEFDevToolsResult.params(params)
        return devToolsOrder.post(browser) { [weak self] in
            self?.sendDevTools(browser, method: method, encodedParams: encoded) != nil
        }
    }

    /// A DevTools method whose answer is awaited, with a few scalar parameters, in `browser`'s order: sent now, in
    /// this turn, when no earlier call of `browser` waits (a page picture leaves before a hide the caller makes next),
    /// else in a turn of its own after the earlier calls. `mayPost` is checked right before the send (the page lives,
    /// the quit did not begin); when it fails, or Chromium refuses the call, the answer throws `refused`.
    ///
    /// - Returns: The answer: the method's JSON result, awaited with `timeout` from the turn the call left.
    func sendDevToolsInOrder(_ browser: Int32, method: String, params: [String: Any], timeout: Duration = CEFRuntime.devToolsTimeout,
                             refused: BrowserTabError, mayPost: @escaping @MainActor @Sendable () -> Bool) -> CEFDevToolsAnswer {
        let encoded = CEFDevToolsResult.params(params)
        let order = devToolsOrder
        let ticket = order.take(browser)
        if order.heads(ticket, of: browser) {
            let sent = mayPost() ? sendDevTools(browser, method: method, encodedParams: encoded) : nil
            order.leave(ticket, of: browser)
            guard let sent else { return CEFDevToolsAnswer { throw refused } }
            return CEFDevToolsAnswer { [weak self] in
                guard let self else { throw BrowserTabError.closed }
                return try await self.result(of: sent, method: method, timeout: timeout)
            }
        }
        // task-owner: one queued DevTools call; it posts in its browser's turn (or is refused there) and ends with its answer.
        // Nonisolated: its main-actor part is ``sendInTurn(_:of:method:encodedParams:timeout:refused:mayPost:)``.
        let answer = Task { @concurrent [weak self] () async throws -> String in
            guard let self else { throw BrowserTabError.closed }
            return try await self.sendInTurn(ticket, of: browser, method: method, encodedParams: encoded, timeout: timeout,
                                             refused: refused, mayPost: mayPost)
        }
        return CEFDevToolsAnswer { try await answer.value }
    }

    /// Waits for `ticket`'s turn in `browser`'s order, then, in that turn, sends the call when `mayPost` still holds and
    /// starts the wait for its answer (so an answer in a later turn finds its waiter).
    private func sendInTurn(_ ticket: CEFDevToolsSendOrder.Ticket, of browser: Int32, method: String, encodedParams: String,
                            timeout: Duration, refused: BrowserTabError, mayPost: @MainActor () -> Bool) async throws -> String {
        await devToolsOrder.turn(ticket, of: browser)
        let sent = mayPost() ? sendDevTools(browser, method: method, encodedParams: encodedParams) : nil
        devToolsOrder.leave(ticket, of: browser)
        guard let sent else { throw refused }
        return try await result(of: sent, method: method, timeout: timeout)
    }

    /// Sends a DevTools method whose parameters are already JSON text, now, in this turn: only through
    /// ``CEFDevToolsSendOrder``, so it keeps its browser's order. The one place cmux calls
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
