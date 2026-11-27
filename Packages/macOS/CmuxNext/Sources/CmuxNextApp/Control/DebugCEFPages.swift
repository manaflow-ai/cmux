import CmuxNextBrowser
import Foundation
import CmuxNextSettings

/// `debug.cef_pages`: every live Chromium page's origin (scheme and host only), whether the content
/// lifecycle hid it, and the renderer client ids that host its frames, so a bench names each
/// renderer process's role (scripts/cmux-next/bench_power.py, scenario `loaded`). Computed only
/// when asked: one shim call per page, no observer and no timer.
@MainActor
func debugCEFPagesReport(_ services: AppServices) -> JSONValue {
    .object(["pages": .array(services.cache.cef.rendererPages.map { page in
        var members: [String: JSONValue] = [
            "browser": .number(Double(page.browserID)), "origin": .string(page.origin), "hidden": .bool(page.hidden), "unresponsive": .bool(page.unresponsive), "exited": .bool(page.exited),
            "loading": .bool(page.loading), "renderer_clients": .array(page.rendererClients.map { .number(Double($0)) }), "on_screen": .bool(page.onScreen), "hang_ends": .number(Double(page.hangEnds)),
        ]
        // cmux's own pages also give their path (the agent page's chat or New Tab), never a query;
        // a browser tab keeps only its origin.
        if page.origin.hasPrefix("cmux-page://") { members["path"] = .string(URL(string: page.url)?.path ?? "") }
        return .object(members)
    }), "page_gc": .object(services.cache.cef.pageCollectorStats.mapValues { .number(Double($0)) })])
}

/// `debug.cef_page_devtools {browser, method, params}`: a DevTools method on one of cmux's own Chromium pages by browser
/// id (`debug.cef_pages`), its JSON reply (``CEFEngine/cmuxPageDevTools(browser:method:params:timeout:)``). `timeout_ms`
/// (default 5000, at most 600000) bounds the wait for Chromium's answer: a script awaited in the page (a measured scroll)
/// may take longer than the default.
@MainActor
func debugCEFPageDevTools(_ params: [String: JSONValue], _ services: AppServices) async -> JSONValue {
    let ms = min(max(params["timeout_ms"]?.intValue ?? 5000, 1), 600_000)
    let answer = await services.cache.cef.cmuxPageDevTools(browser: params["browser"]?.intValue, method: params["method"]?.stringValue,
                                                           params: (params["params"]?.objectValue ?? [:]).mapValues(debugDevToolsValue),
                                                           timeout: .milliseconds(ms))
    return .object([answer.error == nil ? "result" : "error": .string(answer.error ?? answer.result ?? "")])
}

/// A JSON parameter as the Foundation value a DevTools call takes.
func debugDevToolsValue(_ value: JSONValue) -> any Sendable {
    switch value {
    case .null: return NSNull()
    case .bool(let bool): return bool
    case .number(let number): return number.rounded() == number && abs(number) < 1e15 ? Int(number) as any Sendable : number
    case .string(let string): return string
    case .array(let items): return items.map(debugDevToolsValue)
    case .object(let members): return members.mapValues(debugDevToolsValue)
    }
}
