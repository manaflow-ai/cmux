import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

extension AppServices {
    /// Shows tab `id` the way a user's jump does (Go To in history, Search
    /// Tabs, a `cmux://` link): the window that lists its workspace comes
    /// forward (made key only while the app is active), the workspace,
    /// screen and tab are selected and its pane takes focus. Returns false
    /// when no connected machine has the tab.
    ///
    /// - Parameters:
    ///   - id: A daemon tab's id (`TabModel.id`), agent chat tabs included.
    ///   - intent: How the window comes forward; `.bringForward` leaves the
    ///     key window alone (a link opened in the background).
    @discardableResult
    func revealTab(_ id: String, intent: WindowActivation.Intent = .raise) -> Bool {
        let located = locateTabOnAnyMachine(id)
        guard let paneModel = located?.1,
              let workspace = daemon(for: paneModel).store.workspace(containing: paneModel.handle) else { return false }
        // A `tab_` link names a tab the strip may know by its first id.
        return showRevealed(located?.0.id ?? id, in: paneModel, workspaceID: workspace.id, intent: intent)
    }

    /// Shows tab `id` on the named machine, refusing a same-id tab on another machine.
    @discardableResult
    func revealTab(_ id: String, onMachine machineID: String, intent: WindowActivation.Intent = .raise) -> Bool {
        guard let daemon = machines.daemons.first(where: { $0.machineID == machineID }),
              let tab = daemon.store.tab(idOrResource: id),
              let pane = daemon.store.pane(holding: tab),
              let workspace = daemon.store.workspace(containing: pane.handle),
              machines.workspace(id: workspace.id)?.1 === daemon else { return false }
        return showRevealed(tab.id, in: pane, workspaceID: workspace.id, intent: intent)
    }

    /// Shows `tabID` in `pane`; a changed tab is timed here (`debug.tab_switch`): the jump moves the strip before `select`.
    private func showRevealed(_ tabID: String, in pane: PaneModel, workspaceID: String, intent: WindowActivation.Intent) -> Bool {
        guard let window = windows.reveal(workspaceID: workspaceID) else { return false }
        let controller = paneController(for: pane), id = StripTabID(tabID)
        if let controller, controller.stripModel.selectedID != id, ActionRunScope.viewChangeAllowed() { DebugTabSwitch.began(controller) }
        window.state.selection.jump(to: tabID, in: pane.id, byPerson: ActionRunScope.isPersonsAction())
        window.focus.send(.selectTab(pane: pane.id, tab: tabID, workspace: workspaceID, source: .intent))
        controller?.select(id)
        if let nsWindow = window.window { showJumpWindow(nsWindow, intent) }
        return true
    }

    /// The pane with id `id` on any connected machine: its `PaneModel.id`,
    /// or its `pane_` resource id when the model was first seen without one
    /// (its id is then `pane:<handle>`).
    func pane(id: String) -> PaneModel? {
        machines.daemons.lazy.compactMap { $0.store.pane(idOrResource: id) }.first
    }
}

extension AppServices {
    /// Shows the tab that already shows agent session `session` of `harness` (`claude`, `codex`):
    /// the agent chat resuming it, else a live terminal running it (``DeepLink/agentTabs``).
    /// False when no tab shows it; nothing starts, resumes or attaches.
    func revealAgentSession(harness: String, session: String, intent: WindowActivation.Intent = .raise) -> Bool {
        revealedAgentSessionTab(harness: harness, session: session, intent: intent) != nil
    }

    /// ``revealAgentSession(harness:session:intent:)``, returning the tab it showed and whether that
    /// tab is the adopting agent chat.
    func revealedAgentSessionTab(harness: String, session: String,
                                 intent: WindowActivation.Intent = .raise) -> (tab: String, adopted: Bool)? {
        let adopted = agentTabs.tab(resuming: AgentPaneAdopt(harness: harness, agentSessionId: session))
        let tabs = DeepLink.agentTabs(harness: harness, session: session, adopted: adopted,
                                      harnessSessions: machines.daemons.flatMap(\.store.reachableAgentHarnessSessions))
        return tabs.first { revealTab($0, intent: intent) }.map { ($0, $0 == adopted) }
    }
}
