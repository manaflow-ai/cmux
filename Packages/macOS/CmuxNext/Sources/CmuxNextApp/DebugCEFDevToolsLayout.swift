import CmuxNextActions
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import Foundation

// `debug.cef.devtools_layout` (Debug and bench builds; read-only): the focused (or `tab`, a layout tab id) Chromium tab's
// docked DevTools (`CEFDevToolsDebug`): open, dock, sizes, divider grab area.
enum DebugCEFDevToolsLayout {
    static func register(on router: ControlRouter?, services: AppServices) {
        #if DEBUG || CMUX_BENCH_HOOKS
        router?.register([
            .mainActor("debug.cef.devtools_layout") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(handle(call.params, services: services))
            },
        ])
        #endif
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension DebugCEFDevToolsLayout {
    static func handle(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let entry: BrowserEntry?
        if let id = params["tab"]?.stringValue {
            entry = services.cache.existingBrowser(id)
        } else if case .browser(let focused)? = ActionScope(services: services, invocation: ActionInvocation()).pane?.currentContent {
            entry = focused
        } else {
            entry = nil
        }
        guard let tab = entry?.tab as? CEFTab else { return .object(["error": .string("no Chromium tab")]) }
        return JSONValue(foundation: CEFDevToolsDebug(tab).report) ?? .null
    }
}
#endif
