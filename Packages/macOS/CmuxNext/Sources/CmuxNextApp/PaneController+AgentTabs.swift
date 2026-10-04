import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextTabs

extension PaneController {
    /// New Agent Chat: a new agent tab in this pane, selected. It inherits
    /// the selected tab's context (`agentSeedFromSelectedTab`, #16620).
    func newAgentTab() {
        showAgentTab(services.agentTabs.open(in: paneKey, of: daemon.store, seed: agentSeedFromSelectedTab()))
    }

    /// A `cmux://session/<id>` link no tab shows: a new agent tab in this
    /// pane on that session, selected, as Duplicate Tab opens one; its page
    /// refuses a session the daemon does not have. Returns its id.
    @discardableResult
    func openAgentSession(_ session: String) -> String {
        let key = services.agentTabs.openLinked(session: session, in: paneKey, of: daemon.store)
        showAgentTab(key)
        return key
    }

    /// Duplicate Tab on an agent tab: the same session, right after it.
    func duplicateAgentTab(_ key: String) {
        showAgentTab(services.agentTabs.duplicate(key, in: paneKey, of: daemon.store))
    }

    func showAgentTab(_ key: String) {
        apply(snapshot())
        select(StripTabID(key))
    }
}
