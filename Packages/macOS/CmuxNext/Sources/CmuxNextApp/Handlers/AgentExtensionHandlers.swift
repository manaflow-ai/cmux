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
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browser.allowAgentWithExtensions", run: { invocation in
            let entry = try context.page(invocation)
            guard let key = context.services.cache.key(of: entry.tab) else { throw ActionFailure(message: MiscHandlerStrings.noBrowser) }
            context.services.cache.allowAgentWithExtensions(key)
        })
    }

    /// The warning for the focused page: which enabled extensions can read it.
    static func prompt(_ invocation: ActionInvocation, _ context: AppActionContext,
                       access: AgentExtensionAccess = .fromDisk) -> DestructiveConfirmation.Prompt? {
        guard let entry = try? context.page(invocation) else { return nil }
        return prompt(blockers: blockerNames(entry.tab, access: access))
    }

    static func prompt(blockers names: [String]) -> DestructiveConfirmation.Prompt {
        let body = names.isEmpty ? AgentExtensionStrings.bodyNone
            : AgentExtensionStrings.body(ListFormatter.localizedString(byJoining: names))
        return DestructiveConfirmation.Prompt(title: AgentExtensionStrings.title, body: body, button: AgentExtensionStrings.button)
    }

    static func blockerNames(_ tab: any BrowserTab, access: AgentExtensionAccess) -> [String] {
        guard let store = (tab as? any BrowserExtensionActionHosting)?.extensionStore else { return [] }
        store.refresh()
        return access.blockers(store.extensions, url: tab.state.url).map(\.name)
    }
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
