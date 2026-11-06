import AppKit
import Foundation
import Observation

/// The agent pane on the chat's right (user 2026-11-03, msg 19960): a click on an agent's pill opens its chat
/// in a tab there; closing the last tab gives the chat its whole width back.
extension HomeNativeTranscriptView {
    /// Opens agent `peer`'s chat (a click on its pill) as its `aN` link opens (user 2026-11-04, msg 21663: "just
    /// open it as pane to right side"): the Chief's link to its session goes to the host (``onAppLink``), which
    /// opens a real chat tab right of Home. With no link or no host, the agent pane here shows it.
    func openAgent(_ peer: String) {
        guard !stopped else { return }
        if let onAppLink {
            // Opened right of Home: this chat's own pane stays as it was.
            if agentPane.open(peer, outside: { onAppLink($0); return true }) { return }
        } else {
            agentPane.open(peer)
        }
        if agentPaneView == nil {
            let view = HomeAgentPaneView(pane: agentPane)
            view.onGoToWorkspace = { [weak self] url in self?.onAppLink?(url) }
            addSubview(view)
            agentPaneView = view
            followAgentPane()
        }
        agentPaneView?.apply()
        // task-owner: one place read for the open tabs (a moved agent re-attaches); ends when the owner answers
        Task { [agentPane] in await agentPane.followSessions() }
        needsLayout = true
    }

    /// Lays the agent pane out on the right; the width it takes from the chat (0 while hidden).
    func layoutAgentPane() -> CGFloat {
        guard let view = agentPaneView else { return 0 }
        view.isHidden = !agentPane.isShown
        guard agentPane.isShown else { return 0 }
        let width = min(440, max(280, (bounds.width * 0.42).rounded()), max(0, bounds.width - 320))
        let frame = NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
        if view.frame != frame { view.frame = frame }
        return width
    }

    /// Lays the chat out again when the pane shows or hides (its last tab closed).
    private func followAgentPane() {
        withObservationTracking { _ = agentPane.isShown } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.needsLayout = true
                self?.followAgentPane()
            }
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The agent pane's open tabs and the selected one (`debug.home.drive`, tests).
    public var debugAgentPane: (tabs: [String], selected: String?) { (agentPane.tabs, agentPane.selected) }

    /// Opens agent `peer`'s chat as a click on its pill does (`debug.home.drive` `agent_pill`).
    public func debugOpenAgent(_ peer: String) { openAgent(peer) }

    /// Sends `text` from the selected agent's composer, as the person does (`debug.home.drive` `agent_messages` `say`).
    public func debugSendToAgent(_ text: String) -> Bool {
        guard let chat = agentPaneView?.selectedChat, chat.hasComposer else { return false }
        chat.sendFromComposer(text)
        return true
    }
    #endif
}
