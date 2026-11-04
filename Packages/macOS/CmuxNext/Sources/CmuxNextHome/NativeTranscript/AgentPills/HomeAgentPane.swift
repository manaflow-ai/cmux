import CmuxHomeCore
import Foundation
import Observation

/// The agent pane of one Home chat (user 2026-11-03, msg 19960): one tab per agent the person opened from
/// its pill, in the order opened, and the selected one. Opening an agent that has a tab selects it; closing
/// the last tab hides the pane. Selecting an agent marks its newest report seen, so its unread dot clears.
@MainActor
@Observable
final class HomeAgentPane {
    /// The opened agents' ids, in tab order.
    private(set) var tabs: [String] = []
    /// The agent whose chat shows; nil when the pane is hidden.
    private(set) var selected: String?
    /// The chat the pane belongs to.
    let conversation: ConversationID
    private let threads: any HomeAgentThreadReading

    /// - Parameters:
    ///   - conversation: The Home chat whose agents it opens.
    ///   - threads: Where the agents' chats come from and their seen marks go (the shared `HomeStore`).
    init(conversation: ConversationID, threads: any HomeAgentThreadReading) {
        self.conversation = conversation
        self.threads = threads
    }

    /// True while a tab is open.
    var isShown: Bool { !tabs.isEmpty }

    /// Opens agent `peer` (a click on its pill): a new tab at the end, or its existing tab.
    func open(_ peer: String) {
        if !tabs.contains(peer) { tabs.append(peer) }
        select(peer)
    }

    /// Shows agent `peer`'s tab and marks its newest report seen.
    func select(_ peer: String) {
        guard tabs.contains(peer) else { return }
        if selected != peer { selected = peer }
        threads.markAgentSeen(peer, in: conversation)
    }

    /// Closes agent `peer`'s tab; the next one (else the previous) shows, none left hides the pane.
    func close(_ peer: String) {
        guard let index = tabs.firstIndex(of: peer) else { return }
        tabs.remove(at: index)
        guard selected == peer else { return }
        if tabs.isEmpty {
            selected = nil
        } else {
            select(tabs[min(index, tabs.count - 1)])
        }
    }

    /// The selected agent's chat changed while it shows (a new report): it is seen too.
    func selectedChanged() {
        if let selected { threads.markAgentSeen(selected, in: conversation) }
    }

    /// The person sent `text` to agent `peer` from its tab's composer.
    func send(_ text: String, to peer: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tabs.contains(peer), !words.isEmpty else { return }
        threads.sendToAgent(words, peer: peer, in: conversation)
    }

    /// What agent `peer`'s tab shows now; nil when no run has a message with it.
    func content(_ peer: String, now: Date) -> HomeAgentChatContent? {
        threads.agentThread(peer, in: conversation).map {
            HomeAgentChatContent($0, now: now, session: threads.agentSession(peer, in: conversation))
        }
    }

    /// Go to workspace on agent `peer`'s tab: where its session runs at this moment (a read, then a
    /// re-attach when it moved), so the button opens the place it went, never the one it left.
    ///
    /// - Returns: The link to open; nil when the agent has no workspace link.
    func goToWorkspace(_ peer: String) async -> URL? {
        _ = await threads.followAgentSessions([peer], in: conversation)
        return content(peer, now: Date())?.workspaceLink
    }

    /// Reads where the open agents run now (a tab opened or selected): a moved one re-attaches, and its tab
    /// redraws with the new place.
    func followSessions() async {
        _ = await threads.followAgentSessions(tabs, in: conversation)
    }

    /// Agent `peer`'s title for its tab (its id when its chat is not loaded).
    func title(_ peer: String) -> String {
        threads.agentThread(peer, in: conversation)?.title ?? peer
    }
}
