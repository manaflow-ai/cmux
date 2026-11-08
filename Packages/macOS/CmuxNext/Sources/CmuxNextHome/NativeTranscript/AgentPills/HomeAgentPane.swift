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
    /// Agents opened here while queued (no workspace yet): each moves to its workspace once it starts
    /// (``startedWaiting()``, user 2026-11-07, msg 23835).
    private(set) var waiting: Set<String> = []
    /// Agents the person pressed Start now on, until they start.
    private(set) var starting: Set<String> = []
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
        if content(peer, now: Date())?.isQueued == true { waiting.insert(peer) }
        select(peer)
    }

    /// Opens agent `peer` (a click on its pill) as a real cmux pane beside Home when it can (user 2026-11-04,
    /// msg 21663: "just open it as pane to right side"): `outside` gets the Chief's link to the agent's session
    /// (where it runs now) and its report is seen. With no link, or when `outside` could not open it, its chat
    /// opens in this pane instead (``open(_:)``), so the click always shows it.
    ///
    /// - Parameters:
    ///   - peer: The agent's id.
    ///   - outside: Opens the link beside Home; true when it did.
    /// - Returns: True when it opened beside Home; false when it opened in this pane.
    @discardableResult
    func open(_ peer: String, outside: (URL) -> Bool) -> Bool {
        if let link = content(peer, now: Date())?.workspaceLink, outside(link) {
            threads.markAgentSeen(peer, in: conversation)
            return true
        }
        open(peer)
        return false
    }

    /// The agents opened here while queued that have started and have a place to open now, with that place
    /// (the Chief's link, else the session's own). Reads each one's chat, so an observer follows the start.
    func startedWaiting() -> [String: URL] {
        var started: [String: URL] = [:]
        for peer in waiting {
            guard let content = content(peer, now: Date()), !content.isQueued, let link = content.workspaceLink else { continue }
            started[peer] = link
        }
        return started
    }

    /// Hands started agent `peer` to its workspace: `outside` opens `link` beside Home, then its tab here
    /// closes, so the tab becomes the real workspace. False (the tab stays) when `outside` could not open it.
    @discardableResult
    func handOff(_ peer: String, to link: URL, outside: (URL) -> Bool) -> Bool {
        guard waiting.contains(peer), outside(link) else { return false }
        waiting.remove(peer)
        starting.remove(peer)
        threads.markAgentSeen(peer, in: conversation)
        close(peer)
        return true
    }

    /// Start now on queued agent `peer`'s tab: marks it starting (its button says so) and returns true, or
    /// false when it is not queued or already starting. The caller asks the Chief (``failedToStart(_:)`` on a refusal).
    func startNow(_ peer: String) -> Bool {
        guard !starting.contains(peer), content(peer, now: Date())?.isQueued == true else { return false }
        starting.insert(peer)
        waiting.insert(peer)
        return true
    }

    /// The Chief did not start `peer`: Start now shows again.
    func failedToStart(_ peer: String) {
        starting.remove(peer)
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
        waiting.remove(peer)
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
        guard let thread = threads.agentThread(peer, in: conversation) else { return nil }
        var content = HomeAgentChatContent(thread, now: now, session: threads.agentSession(peer, in: conversation))
        if content.isQueued {
            content.ahead = threads.queuedAgents(in: conversation).firstIndex(of: peer)
            content.isStarting = starting.contains(peer)
        }
        return content
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
