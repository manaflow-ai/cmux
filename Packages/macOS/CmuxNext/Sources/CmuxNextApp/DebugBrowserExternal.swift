import CmuxNextActions
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextOnboarding
import CmuxNextSettings
import Foundation

// `debug.external_open`, `debug.browser.external_opens`, `debug.browser.prompts` and `debug.browser.page_status`
// (DEBUG builds), for the scripts/cmux-next live checks: the links a recording build sent
// to other apps (`BrowserExternalApps`), a browser tab's pending prompts, and the cmux
// pages over a tab's page (error page, certificate warning, sad tab, Page unresponsive;
// `press` presses Proceed, Wait or Exit page).
enum DebugBrowserExternal {
    static func register(on router: ControlRouter?, services: AppServices) {
        #if DEBUG
        router?.register([
            .mainActor("debug.browser.external_opens") { call in .value(opens(call.params)) },
            // `{url}` as macOS hands it to cmux from another app (`ssh://host`): captures and live checks.
            .mainActor("debug.external_open") { [weak services] call in
                guard let services, let url = call.params["url"]?.stringValue.flatMap(URL.init(string:)) else { return .value(.bool(false)) }
                return .value(.bool(services.externalOpen.open(url)))
            },
            // `{id, title?, harness?, host}`: the cmux://session question for that session, in the
            // active window, without a link (captures; a capture host has no acpmux sessions).
            .mainActor("debug.session_link_ask") { [weak services] call in
                let p = call.params
                let subject = SessionLinkSubject(id: p["id"]?.stringValue ?? "ses-capture", title: p["title"]?.stringValue,
                                                 harness: p["harness"]?.stringValue, host: p["host"]?.stringValue ?? SessionLinkSubject.thisMac)
                let window = services?.windows.active?.window
                Task { _ = await SessionLinkGate.ask(subject, in: window) }
                return .value(.bool(window != nil))
            },
            .mainActor("debug.browser.prompts") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(prompts(call.params, services: services))
            },
            .mainActor("debug.browser.page_status") { [weak services] call in
                guard let services else { return .value(.null) }
                guard let chrome = entry(call.params, services: services)?.chrome else {
                    return .value(.object(["error": .string("no browser tab")]))
                }
                var fields = PageStatusDebug(chrome, press: call.params["press"]?.stringValue).fields
                // How a restored page started (`BrowserHistoryStarts`) and whether its history keeps engine state.
                if let key = chrome.addressBar.tabKey {
                    fields["history_start"] = services.cache.browserTabs.historyStarts.outcomes[key] ?? ""
                    fields["engine_state_saved"] = services.cache.browserTabs.historyWriters[key]?.savedEngineState == true ? "1" : "0"
                }
                return .value(.object(fields.mapValues { .string($0) }))
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
        guard let tab = entry(params, services: services)?.tab else { return .object(["error": .string("no browser tab")]) }
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

    /// The `tab` param's browser (a layout tab id), else the focused one.
    static func entry(_ params: [String: JSONValue], services: AppServices) -> BrowserEntry? {
        if let id = params["tab"]?.stringValue { return services.cache.existingBrowser(id) }
        guard case .browser(let focused)? = ActionScope(services: services, invocation: ActionInvocation()).pane?.currentContent else {
            return nil
        }
        return focused
    }
}
#endif
