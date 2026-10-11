import CmuxNextActions
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import Foundation

// `debug.browser.external_opens` and `debug.browser.prompts` (DEBUG builds), for
// scripts/cmux-next/external-schemes-live.py: the links a recording build sent to
// other apps (`BrowserExternalApps`), and a browser tab's pending prompts.
enum DebugBrowserExternal {
    static func register(on router: ControlRouter?, services: AppServices) {
        #if DEBUG
        router?.register([
            .mainActor("debug.browser.external_opens") { call in .value(opens(call.params)) },
            .mainActor("debug.browser.prompts") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(prompts(call.params, services: services))
            },
        ])
        #endif
    }
}

#if DEBUG
extension DebugBrowserExternal {
    /// `{clear?}`: the URLs opened in other apps since the last clear (recording builds,
    /// `CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1`).
    static func opens(_ params: [String: JSONValue]) -> JSONValue {
        let apps = BrowserExternalApps.shared
        let urls = apps.recorded.map { JSONValue.string($0.absoluteString) }
        if params["clear"]?.boolValue == true { apps.clearRecorded() }
        return .object(["urls": .array(urls)])
    }

    /// `{tab?, respond?}`: the focused (or `tab`, a layout tab id) browser tab's pending
    /// prompts, the one the prompt bar shows first; `respond` (`allow`, `allowOnce`,
    /// `accept`, `cancel`, `deny`) answers that one, as its button does.
    static func prompts(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let entry: BrowserEntry?
        if let id = params["tab"]?.stringValue {
            entry = services.cache.existingBrowser(id)
        } else if case .browser(let focused)? = ActionScope(services: services, invocation: ActionInvocation()).pane?.currentContent {
            entry = focused
        } else {
            entry = nil
        }
        guard let tab = entry?.tab else { return .object(["error": .string("no browser tab")]) }
        var result: [String: JSONValue] = [:]
        if let answer = params["respond"]?.stringValue {
            let response: BrowserPromptResponse? = switch answer {
            case "allow": .allow
            case "allowOnce": .allowOnce
            case "accept": .accept
            case "cancel": .cancel
            case "deny": .deny
            default: nil
            }
            let first = tab.pendingPrompts.first
            if let response, let first { first.respond(response) }
            result["responded"] = .bool(response != nil && first != nil)
        }
        result["prompts"] = .array(tab.pendingPrompts.map { prompt in
            .object(["kind": .string(String(describing: prompt.kind)), "origin": .string(prompt.origin)])
        })
        return .object(result)
    }
}
#endif
