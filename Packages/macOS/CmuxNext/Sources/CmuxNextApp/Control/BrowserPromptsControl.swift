import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextPopups
import CmuxNextSettings

/// `browser.prompts` and `browser.popups`, in every build: what a browser tab or a
/// window.open popup is asking the person now (a sign-in, an external app link, a
/// permission), so a script or an agent can check a login flow in a release
/// NIGHTLY, which registers no `debug.*` methods.
///
/// - `browser.prompts {tab?}`: the tab's pending prompts (`kind`, `origin`), read-only;
///   `tab` is a layout tab id, else the focused browser tab.
/// - `browser.popups {action?}`: each open popup window (`url`, `engine`, `key`,
///   `visible`, `opener_tab`, its pending `prompts`, `prompt_shown`). `{"action":
///   "close"}` closes them all, as the person can.
@MainActor
enum BrowserPromptsControl {
    static func methods(_ services: AppServices) -> [ControlMethod] {
        [
            .mainActor("browser.prompts") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(prompts(call.params, services: services))
            },
            .mainActor("browser.popups") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(popups(call.params, services: services))
            },
        ]
    }

    static func prompts(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let tab = entry(params, services: services)?.tab else { return .object(["error": .string("no browser tab")]) }
        return .object(["prompts": .array(tab.pendingPrompts.map { prompt in
            .object(["kind": .string(String(describing: prompt.kind)), "origin": .string(prompt.origin)])
        })])
    }

    static func popups(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        if params["action"]?.stringValue == "close" { services.popups.closeAll() }
        return .object(["panels": .array(services.popups.windows.map { panel in
            let page = panel.page
            return .object([
                "url": page.state.url.map { .string($0.absoluteString) } ?? .null,
                "engine": .string(page.engineKind == .cef ? "chromium" : "webkit"),
                "key": .bool(panel.isKeyWindow),
                "visible": .bool(panel.isVisible),
                "opener_tab": services.popups.openerKey(of: page).map { .string($0) } ?? .null,
                "prompts": .array(page.pendingPrompts.map { .object(["kind": .string(String(describing: $0.kind))]) }),
                "prompt_shown": .bool(panel.showsPrompts),
            ])
        })])
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
