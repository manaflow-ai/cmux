import CmuxNextActions
import CmuxNextAgentPane

/// Integrate a Harness… (BRING-YOUR-OWN-HARNESS H3, cx-uj5g8): the palette and the File menu run
/// this action. It opens an agent tab in the focused pane on its Harnesses page: the harnesses on
/// this Mac with their state and Start Chat, Sign In or Install…, and Custom harness…, which starts the
/// `cmux harness guide` chat in that tab. The model picker's + shows the same page in place.
enum AddHarnessHandler {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.addHarness", run: { invocation in
            // A new tab takes the focus: automation runs `cmux harness guide` itself.
            guard invocation.allowsViewChange else { return context.refuse(AddHarnessStrings.needsFocus) }
            // A focused New Tab page shows the page in place, as its own button does (cx-9fqw).
            if let pane = context.scope(invocation).pane, let key = pane.currentTabKey, context.services.agentTabs.isNewTabPage(key),
               let view = context.services.agentTabs.existingView(key) {
                // No tab opens: a chat the page then starts records its own kind.
                return AgentPaneHarnessesPage(view).show()
            }
            // The same pane path as New Agent Chat: from Home a new workspace on the Harnesses
            // page; from a settling workspace its first pane, then the tab there.
            AgentHandlers.withAgentPane(invocation, context: context, seed: seed) { pane in
                pane.openAgentTab(seed: AgentPaneSeedSource(seed))
            }
        })
    }

    /// The tab's seed: no folder (the relay fills the pane's chat folder), on the Harnesses page.
    static var seed: AgentPaneSeed { AgentPaneSeed(showsHarnesses: true) }
}

enum AddHarnessStrings {
    static var needsFocus: String {
        String(localized: "handlers.agent.addHarness.needsFocus",
               defaultValue: "Add Harness… opens the Harnesses page from the palette or the menu. Automation runs cmux harness guide instead.",
               table: "MiscHandlers", bundle: .module)
    }
}
