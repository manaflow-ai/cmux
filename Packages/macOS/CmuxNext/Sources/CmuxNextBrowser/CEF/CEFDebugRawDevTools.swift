import Foundation

#if DEBUG
/// DEBUG builds only: drives the raw DevTools shim calls on a tab and keeps
/// what came back, so a live check (`debug.cef.raw`) can prove that raw
/// replies arrive as `CMUX_SHIM_DEVTOOLS_EVENT` (32) and never as
/// `DEVTOOLS_RESULT` (13).
@MainActor
public enum CEFDebugRawDevTools {
    /// Event 32 messages, newest last (at most 200).
    public private(set) static var messages: [(browser: Int32, json: String)] = []
    /// DEVTOOLS_RESULT ids seen, newest last (at most 200).
    public private(set) static var resultIDs: [(browser: Int32, id: Int32)] = []

    static func record(_ event: CEFShimEvent) {
        switch event {
        case .devToolsMessage(let browser, let json):
            messages.append((browser, json))
            if messages.count > 200 { messages.removeFirst(messages.count - 200) }
        case .devToolsResult(let browser, let id, _, _):
            resultIDs.append((browser, id))
            if resultIDs.count > 200 { resultIDs.removeFirst(resultIDs.count - 200) }
        default:
            break
        }
    }

    public static func clear() {
        messages.removeAll()
        resultIDs.removeAll()
    }

    /// `cmux_shim_devtools_watch_events`; false when the tab has no browser yet.
    public static func watch(_ tab: CEFTab, _ enabled: Bool) -> Bool {
        guard let browser = tab.browserID, let shim = tab.runtime.shim else { return false }
        shim.devToolsWatchEvents(browser, enabled ? 1 : 0)
        return true
    }

    /// `cmux_shim_devtools_send`: 1 sent, 0 gone, -1 refused; nil without a browser.
    public static func send(_ tab: CEFTab, _ json: String) -> Int32? {
        guard let browser = tab.browserID, let shim = tab.runtime.shim else { return nil }
        return json.withCString { shim.devToolsSend(browser, $0) }
    }

    /// The fork API version and shim ABI identity the runtime loaded.
    public static func runtimeInfo(_ tab: CEFTab) -> (forkAPI: Int32, abi: String)? {
        guard let shim = tab.runtime.shim else { return nil }
        return (shim.forkAPIVersion(), shim.abiIDFn().map { String(cString: $0) } ?? "")
    }
}
#endif
