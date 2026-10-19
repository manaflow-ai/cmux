import CmuxNextActions
import CmuxNextDaemon
import CmuxNextFocus

// `cmux://agent/<harness>/<session>` (hq#2555): what the app can already reach, and the
// keyboard after the reveal. Nothing here starts, resumes, attaches or types.
extension AppServices {
    /// The terminal tabs of every connected machine with the agent and harness session id their
    /// hooks reported (``CmuxNextControl`` publishes the same as `agentHarnessSessionID`).
    func agentLinkCandidates() -> [DeepLink.AgentCandidate] {
        var candidates: [DeepLink.AgentCandidate] = []
        for (workspace, _) in machines.allWorkspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs {
                        // Hook bookkeeping values (`cmux-hook-…`) are not a session.
                        guard let session = tab.agent?.session, !session.isEmpty, !session.hasPrefix("cmux-hook-") else { continue }
                        candidates.append(DeepLink.AgentCandidate(tab: tab.id, harness: tab.agent?.agent, session: session))
                    }
                }
            }
        }
        return candidates
    }

    /// Gives the keyboard to tab `id`'s content after ``revealTab(_:intent:)`` showed it: a
    /// terminal's surface, or an agent chat's page, whose composer takes an idle focus
    /// (composerFocus.ts). The focus model's own path, as returning to a page's content does.
    func focusContent(ofTab id: String) {
        guard let paneModel = locateTab(id)?.1,
              let workspace = daemon(for: paneModel).store.workspace(containing: paneModel.handle),
              let window = windows.reveal(workspaceID: workspace.id) else { return }
        if window.focus.state.pane != paneModel.id { window.focus.send(.focusPane(paneModel.id, source: .intent)) }
        window.focus.send(.focusTarget(.content, source: .intent))
    }
}
