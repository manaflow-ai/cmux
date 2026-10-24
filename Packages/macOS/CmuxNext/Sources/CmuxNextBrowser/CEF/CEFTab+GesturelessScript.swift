import Foundation

/// `Runtime.evaluate` without `userGesture` (its default): the page-world path of
/// `evaluate(_:world:)` sets it for agents' clicks; the hibernation probe must not.
extension CEFTab: BrowserGesturelessScripting {
    public func evaluateWithoutUserGesture(_ script: String) async throws -> BrowserJSValue {
        guard let browserID, !isClosed else { throw BrowserTabError.closed }
        let json = try await runtime.devTools(browserID, method: "Runtime.evaluate",
                                              params: ["expression": script, "returnByValue": true, "awaitPromise": true])
        return try CEFDevToolsResult.evaluation(json)
    }
}
