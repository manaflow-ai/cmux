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
            "browser": .number(Double(page.browserID)), "origin": .string(page.origin), "hidden": .bool(page.hidden),
            "renderer_clients": .array(page.rendererClients.map { .number(Double($0)) }),
        ]
        // cmux's own pages also give their path (the agent page's chat or New Tab), never a query;
        // a browser tab keeps only its origin.
        if page.origin.hasPrefix("cmux-page://") { members["path"] = .string(URL(string: page.url)?.path ?? "") }
        return .object(members)
    })])
}

/// `debug.cef_page_devtools {browser, method, params}`: a DevTools method on one of cmux's own
/// Chromium pages by browser id (`debug.cef_pages`), its JSON reply. The idle bench reads each
/// shown page's metrics and CPU profile with it. Browser tabs are refused: this reads only cmux's pages.
@MainActor
func debugCEFPageDevTools(_ params: [String: JSONValue], _ services: AppServices) async -> JSONValue {
    guard let id = params["browser"]?.intValue, let browser = Int32(exactly: id), let method = params["method"]?.stringValue else {
        return .object(["error": .string("browser (a browser id) and method are required")])
    }
    guard let page = services.cache.cef.rendererPages.first(where: { $0.browserID == browser }) else {
        return .object(["error": .string("no live page \(browser)")])
    }
    guard page.origin.hasPrefix("cmux-page://") else { return .object(["error": .string("only cmux's own pages")]) }
    var arguments: [String: any Sendable] = [:]
    for (key, value) in params["params"]?.objectValue ?? [:] { arguments[key] = debugDevToolsValue(value) }
    do {
        guard let reply = try await services.cache.cef.devTools(browserID: browser, method: method, params: arguments) else {
            return .object(["error": .string("no live page \(browser)")])
        }
        return .object(["result": .string(reply)])
    } catch {
        return .object(["error": .string(String(describing: error))])
    }
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
