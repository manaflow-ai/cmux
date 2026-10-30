import Foundation

extension CEFTab {
    /// Runs `script` in the page's main frame, in the page's own world, and keeps no answer: a command
    /// whose value nobody reads (a menu's Copy, `document.execCommand('copy')`), sent in the caller's
    /// turn with nothing waiting on it. The fork's `tabEvaluate` on renderer paths (fork API 29), with no
    /// DevTools session; a `Runtime.evaluate` on an older fork.
    ///
    /// - Parameters:
    ///   - script: The script.
    ///   - gesture: `.agent` runs it as the person's own command (a menu choice); `.cmux` without a gesture.
    /// It goes in the browser's call order (``CEFDevToolsSendOrder``): after every earlier call to the page.
    ///
    /// - Returns: False when the browser is gone or the call could not leave.
    public func perform(_ script: String, gesture: BrowserScriptGesture) -> Bool {
        guard let browserID, !isClosed, runtime.shim != nil else { return false }
        if runtime.forkFeatures.rendererPaths {
            let runtime = runtime, agent = gesture == .agent
            return runtime.devToolsOrder.post(browserID) { [weak runtime] in
                runtime?.perform(browserID, world: "", script: script, userGesture: agent) ?? false
            }
        }
        var params: [String: Any] = ["expression": script]
        if gesture == .agent { params["userGesture"] = true }
        // Its DEVTOOLS_RESULT finds no waiter and is dropped.
        return runtime.postDevTools(browserID, method: "Runtime.evaluate", params: params)
    }
}
