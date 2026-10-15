import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// The app side of ``AgentSidePanes`` (New side chat, `/btw` side sessions): the tracker decides
/// between a tab in the chat's side pane and a new split; this opens the tab there and focuses it,
/// or opens it beside the chat and moves it to a split on its right (``AgentTabStore/openBeside``).
@MainActor
enum AgentSidePanePlacement {
    /// Opens side session `session` of chat session `chat` beside chat tab `provisional`.
    static func open(_ session: String, of chat: String, beside provisional: String, in tabs: AgentTabStore) {
        AgentSidePanes.chat(chat).open(session, chat: tabs.resolve(provisional), hooks: .init(pane: { [weak tabs] key in
            tabs?.locate(tabs?.resolve(key) ?? key).map { "\(ObjectIdentifier($0.daemon).hashValue):\($0.pane.rawValue)" }
        }, addTab: { [weak tabs] anchor, session, created, finished in
            guard let tabs, let (pane, daemon) = tabs.locate(tabs.resolve(anchor)),
                  let pending = try? tabs.open(in: pane, of: daemon, session: session) else { return false }
            // task-owner: one tab creation in the side pane, then one focus of that tab
            Task { [weak tabs] in
                guard let tab = try? await pending.value(), let tabs, await TabMirror.reaches(tab.key, in: tabs.locate) else { finished(); return }
                created(tab.key)
                _ = tabs.actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.key), origin: .user))
                finished()
            }
            return true
        }, split: { [weak tabs] session, created, finished in
            tabs?.openBeside(provisional, open: { [weak tabs] pane, daemon in
                guard let tabs else { throw CancellationError() }
                return try tabs.open(in: pane, of: daemon, session: session)
            }, created: created, finished: { _ in finished() }) ?? false
        }))
    }
}
