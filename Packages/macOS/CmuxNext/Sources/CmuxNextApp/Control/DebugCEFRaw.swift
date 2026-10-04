import CmuxNextBrowser
import CmuxNextSettings
import Foundation

/// `debug.cef.raw` (DEBUG builds): the raw DevTools shim calls on the
/// focused Chromium tab, for the cmux.16 live check. Params `action`:
/// `info` (fork API, shim ABI identity), `watch` (`enabled`), `send`
/// (`message`, raw JSON; answers the shim's 1 / 0 / -1), `log` (event 32
/// messages and DEVTOOLS_RESULT ids so far), `clear`, `load` (`url`, loaded
/// as given, without the omnibox resolver).
@MainActor
enum DebugCEFRaw {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        #if DEBUG
        guard let key = services.windows.active?.focusedPane?.selectedTab?.id,
              let tab = services.cache.existingBrowser(key)?.tab as? CEFTab else {
            return ["error": "the focused tab is not a live Chromium page"]
        }
        switch params["action"]?.stringValue ?? "info" {
        case "info":
            guard let info = CEFDebugRawDevTools.runtimeInfo(tab) else { return ["error": "no shim"] }
            return ["fork_api": .number(Double(info.forkAPI)), "abi": .string(info.abi), "browser": .number(Double(tab.browserID ?? 0))]
        case "watch":
            return ["ok": .bool(CEFDebugRawDevTools.watch(tab, params["enabled"]?.boolValue ?? true))]
        case "send":
            guard let message = params["message"]?.stringValue else { return ["error": "message is required"] }
            return CEFDebugRawDevTools.send(tab, message).map { ["result": .number(Double($0))] } ?? ["error": "no browser"]
        case "log":
            return [
                "messages": .array(CEFDebugRawDevTools.messages.map { ["browser": .number(Double($0.browser)), "json": .string($0.json)] }),
                "result_ids": .array(CEFDebugRawDevTools.resultIDs.map { .number(Double($0.id)) }),
            ]
        case "clear":
            CEFDebugRawDevTools.clear()
            return ["ok": true]
        case "load":
            guard let text = params["url"]?.stringValue, let url = URL(string: text) else { return ["error": "url is required"] }
            tab.load(url)
            return ["ok": true]
        default:
            return ["error": "unknown action"]
        }
        #else
        return ["error": "DEBUG builds only"]
        #endif
    }
}
