import CmuxNextDaemon

/// The chat header's toggling quick actions (acpmux header/quickActions.ts, `mode: "toggle"`, the
/// default, as in T3 Chat and ChatGPT): the first click on Terminal or Browser opens its split beside
/// the chat, the second closes that split, and a click after the user closed it opens a new one.
///
/// One per chat tab. Opening records the tabs of the chat's workspace; the split's tab is the tab of
/// the button's kind that appeared after that, read from the store mirror when the button is clicked
/// again, so no reply plumbing from the split handlers is needed and a split the user closed or moved
/// away from the workspace simply opens again. Durable tab ids, never pane handles (refreshed on every
/// snapshot).
@MainActor
final class AgentChatSplitToggles {
    /// The tab kind each toggling header action opens.
    private static let kinds: [String: TabKind] = ["splitRight": .pty, "splitBrowserRight": .browser]

    /// Per header action: the workspace's tab ids just before it opened its split.
    private var baselines: [String: Set<String>] = [:]

    /// Toggles header action `id` on chat tab `chat` (in `store`): closes the split it opened when
    /// that tab is still in the chat's workspace, else runs the action (an action that opens no
    /// tracked kind just runs).
    func toggle(_ id: String, cwd: String?, chat: String, store: DaemonStore?, actions: AgentChatTabActions) {
        guard let kind = Self.kinds[id], let tabs = store.flatMap({ Self.workspaceTabs(of: chat, in: $0) }) else {
            return actions.run(id, cwd: cwd)
        }
        if let baseline = baselines.removeValue(forKey: id),
           let opened = tabs.first(where: { $0.kind == kind && $0.id != chat && !baseline.contains($0.id) }) {
            return actions.close(tab: opened.id)
        }
        baselines[id] = Set(tabs.map(\.id))
        actions.run(id, cwd: cwd)
    }

    /// Every tab of the workspace that shows chat tab `chat`; nil when the store does not list it.
    private static func workspaceTabs(of chat: String, in store: DaemonStore) -> [TabModel]? {
        guard let surface = store.tab(id: chat)?.surface,
              let pane = store.pane(containing: surface),
              let workspace = store.workspace(containing: pane.handle) else { return nil }
        return workspace.screens.flatMap { $0.panes.flatMap(\.tabs) }
    }
}
