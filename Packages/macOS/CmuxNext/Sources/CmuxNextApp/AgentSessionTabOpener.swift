import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

/// Opens an acpmux session's chat as a tab. The one shared path of `agent.openSessionTab` (CLI
/// `agent open-tab`, MCP `app_agent_open_tab`), a click on a sub-session nested in the sidebar, a
/// chat page's `chat.offer.open`, and a new sub-session opening beside its chat
/// (``AgentSubsessionAutoOpen``).
///
/// A tab that shows the session already is reused: shown, and focused only with `focus`. Else the
/// chat opens beside tab `anchor` (the parent chat's tab): in that chat's side pane when one is
/// open, else in a split right of it, the pane New side chat and `/btw` use (``AgentSidePanes``).
/// Else it opens as a tab in `fallback`. Focus moves only with `focus` (a person's click, or a run
/// that asked for it); an unfocused open moves its tab with `keep_focus`, so the person's focus
/// stays where it is, and the run's own view-change permission still applies to every step.
struct AgentSessionTabOpener {
    let tabs: AgentTabStore

    /// Opens `session` (see the type). `onTab` gets the tab that shows it, or nil when none
    /// opened, exactly once. False when nothing could start (`onTab` got nil).
    @discardableResult
    func open(_ session: String, beside anchor: String?, fallback: (pane: PaneID, daemon: DaemonService)? = nil,
              focus: Bool, onTab: @escaping @MainActor (String?) -> Void = { _ in }) -> Bool {
        let anchor = anchor.map(tabs.resolve).flatMap { tabs.locate($0) == nil ? nil : $0 }
        switch AgentSessionTabPlan.choose(existing: tabs.tab(showing: session), anchor: anchor, pane: fallback?.pane) {
        case .existing(let tab):
            if focus { show(tab) }
            onTab(tab)
            return true
        case .beside(let anchor):
            let store = tabs
            let pane: (String) -> String? = { [weak store] key in
                store?.locate(store?.resolve(key) ?? key).map { "\(ObjectIdentifier($0.daemon).hashValue):\($0.pane.rawValue)" }
            }
            // One tracker per parent chat, shared with its side chats: later sub-sessions stack as tabs in that pane.
            return AgentSidePanes.chat(store.session(of: anchor) ?? anchor).open(session, chat: anchor, pane: pane) { side, created, finished in
                // An open queued behind another one of the same session finds its tab: no second tab.
                if let shown = store.tab(showing: session) {
                    if focus { show(shown) }
                    onTab(shown)
                    finished()
                    return true
                }
                guard let (pane, daemon) = store.locate(store.resolve(side ?? anchor)) else {
                    onTab(nil)
                    return false
                }
                return place(session, in: pane, of: daemon, split: side == nil, focus: focus, onTab: { tab in
                    if let tab { created(tab) }
                    onTab(tab)
                }, finished: finished)
            }
        case .pane(let pane):
            guard let daemon = fallback?.daemon else {
                onTab(nil)
                return false
            }
            return place(session, in: pane, of: daemon, split: false, focus: focus, onTab: onTab, finished: {})
        case .refused:
            onTab(nil)
            return false
        }
    }

    /// A tab on `session` in `pane`, moved to a new split right of it with `split`, then shown
    /// with `focus`. `onTab` gets the tab (nil when it did not open) before the move; `finished`
    /// runs once the move landed.
    private func place(_ session: String, in pane: PaneID, of daemon: DaemonService, split: Bool, focus: Bool,
                       onTab: @escaping @MainActor (String?) -> Void, finished: @escaping @MainActor () -> Void) -> Bool {
        let pending: AgentTabPending
        do {
            pending = try tabs.open(in: pane, of: daemon, session: session, linked: true)
        } catch {
            daemon.logger.error("open session tab: \((error as? AgentTabRefusal)?.message ?? String(describing: error), privacy: .public)")
            onTab(nil)
            return false
        }
        let opener = self, store = tabs
        // task-owner: one tab creation, then one move (or none) and one show of that tab
        Task {
            guard let tab = try? await pending.value(), await TabMirror.reaches(tab.key, in: store.locate) else {
                onTab(nil)
                finished()
                return
            }
            onTab(tab.key)
            if split {
                // An unfocused open keeps focus where it is (`keep_focus`, cx-3hw0i), as a subagent pane does.
                _ = store.actionRegistry?.perform("tab.moveToNewSplit", invocation: ActionInvocation(
                    target: ActionTargetRef(kind: .tab, id: tab.key),
                    arguments: ["direction": .string("right"), "keep_focus": .bool(!focus)], origin: focus ? .user : .script))
                _ = await TabMirror.reaches(tab.key, in: { store.locate($0).flatMap { $0.pane != pane ? $0 : nil } })
            }
            if focus { opener.show(tab.key) }
            finished()
        }
        return true
    }

    /// A person's click on a sub-session nested in the sidebar (`SidebarSubsessionRow`): its chat
    /// opens beside its parent's tab, reusing a tab that shows it already, and takes focus because
    /// a person asked for it. Without the parent's tab it opens in the focused pane. False for a
    /// header row or when nothing could open.
    @discardableResult
    static func openSubsession(_ row: SidebarSubsessionRowID, services: AppServices) -> Bool {
        guard let session = row.session else { return false }
        let fallback = services.windows.active?.focusedPane.map { (pane: $0.pane.handle, daemon: $0.daemon) }
        return AgentSessionTabOpener(tabs: services.agentTabs).open(session, beside: row.parentTab.rawValue, fallback: fallback, focus: true)
    }

    /// Shows tab `key` and focuses it (`tab.focus`), within the run's view-change permission.
    private func show(_ key: String) {
        _ = tabs.actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tabs.resolve(key)),
                                                                                    origin: .user))
    }
}

/// The tab one ``AgentSessionTabOpener/open(_:beside:fallback:focus:onTab:)`` opened, for a caller
/// that waits for it (`agent.openSessionTab` with `wait`): the first answer counts.
final class AgentSessionTabWaiter {
    private var answered = false
    private var tab: String?
    private var waiting: CheckedContinuation<String?, Never>?

    func finish(_ tab: String?) {
        guard !answered else { return }
        answered = true
        self.tab = tab
        waiting?.resume(returning: tab)
        waiting = nil
    }

    func value() async -> String? {
        if answered { return tab }
        return await withCheckedContinuation { self.waiting = $0 }
    }
}
