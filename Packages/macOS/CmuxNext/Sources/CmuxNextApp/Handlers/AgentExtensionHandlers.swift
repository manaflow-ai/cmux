import CmuxNextActions
import CmuxNextBrowser
import Foundation

/// "Allow Agents in This Tab…" (`browser.allowAgentWithExtensions`): the
/// person lifts the interim extension guard for one tab, after a native
/// warning that names the extensions that can read the page
/// (plans/cmux-next/passwords.md, section 3.4). Person-only: the control
/// socket refuses it whatever origin a caller claims, and the destructive
/// confirmation sheet runs before the handler.
enum AgentExtensionHandlers {
    // Stub (plans/cmux-next/passwords.md, 3.4); the action lands next.
    static func prompt(blockers names: [String]) -> DestructiveConfirmation.Prompt {
        DestructiveConfirmation.Prompt(title: "", body: "", button: "")
    }

    static func blockerNames(_ tab: any BrowserTab, access: AgentExtensionAccess) -> [String] { [] }
}

enum AgentExtensionStrings {
    static var title: String {
        String(localized: "confirm.allowAgent.title", defaultValue: "Allow agents in this tab?", table: "Handlers", bundle: .module)
    }
    static func body(_ names: String) -> String {
        String(format: String(localized: "confirm.allowAgent.body",
                              defaultValue: "%@ can read and fill this page. An agent that drives this tab could read a password that these extensions fill. This lasts until the tab closes.",
                              table: "Handlers", bundle: .module), names)
    }
    static var bodyNone: String {
        String(localized: "confirm.allowAgent.bodyNone",
               defaultValue: "No enabled extension can read this page now. If one is enabled later, agents can still drive this tab until it closes.",
               table: "Handlers", bundle: .module)
    }
    static var button: String {
        String(localized: "confirm.allowAgent.button", defaultValue: "Allow Agents", table: "Handlers", bundle: .module)
    }
}
