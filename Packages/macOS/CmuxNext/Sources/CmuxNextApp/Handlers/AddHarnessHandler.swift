import CmuxNextActions
import CmuxNextAgentPane

/// Add Harness… (BRING-YOUR-OWN-HARNESS H3): the palette, the File menu and the New Tab page's
/// "Integrate a harness" button run this one action. It opens a new agent chat in the focused
/// pane, in the pane's usual chat folder (the workspace's folder, else its agent-home), with the
/// guide request in the composer. The user sends it: a page cannot send a prompt without a gesture
/// in the page, and this action runs from outside it.
enum AddHarnessHandler {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.addHarness", run: { invocation in
            // A new tab takes the focus: automation runs `cmux harness guide` itself.
            guard invocation.allowsViewChange else { return context.refuse(AddHarnessStrings.needsFocus) }
            // The same pane path as New Agent Chat: from Home or a settling workspace it makes the
            // first pane, then opens the chat there.
            AgentHandlers.withAgentPane(invocation, context: context) { pane in
                if invocation.origin == .user { context.services.newTabKinds.record(.agent, folder: nil) }
                pane.openAgentTab(seed: AgentPaneSeedSource(seed))
            }
        })
    }

    /// The new chat's seed: no folder (the relay fills the pane's chat folder) and the request.
    static var seed: AgentPaneSeed { AgentPaneSeed(draft: AddHarnessStrings.request) }
}

enum AddHarnessStrings {
    /// The composer text of the chat Add Harness… opens. The command stays as written.
    static var request: String {
        String(localized: "handlers.agent.addHarness.request",
               defaultValue: "Integrate my harness into cmux. Run `cmux harness guide` and follow it.",
               table: "MiscHandlers", bundle: .module)
    }

    static var needsFocus: String {
        String(localized: "handlers.agent.addHarness.needsFocus",
               defaultValue: "Add Harness… opens a chat from the palette, the menu or the New Tab page. Automation runs cmux harness guide instead.",
               table: "MiscHandlers", bundle: .module)
    }
}
