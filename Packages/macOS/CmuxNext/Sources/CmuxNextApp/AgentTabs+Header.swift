import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// The chat header's tools and "..." menu (acpmux header/ChatHeaderTools.tsx): app actions on
/// the chat's own tab, the tab state the menu's labels read, and New side chat's split.
extension AgentTabStore {
    func wireHeader(_ model: AgentPaneModel, key provisional: String) {
        model.header = AgentPaneHeaderHooks(
            run: { [weak self] id, cwd in
                guard let self else { return }
                let target = ActionTargetRef(kind: .tab, id: resolve(provisional))
                let arguments: [String: ActionValue] = cwd.map { ["cwd": .string($0)] } ?? [:]
                _ = actionRegistry?.perform(ActionID(rawValue: id), invocation: ActionInvocation(target: target, arguments: arguments, origin: .user))
            },
            tabState: { [weak self] in
                guard let self else { return [:] }
                let key = resolve(provisional)
                return ["pinned": lookup(key)?.store.tab(id: key)?.pinned ?? false]
            },
            openSide: { [weak self] session in self?.openSide(session, beside: provisional) }
        )
    }

    /// A tab on `session` in the chat's pane, then moved to a new split on its right
    /// (`tab.moveToNewSplit`), so the chat stays where it is.
    private func openSide(_ session: String, beside provisional: String) {
        guard let (pane, daemon) = locate(resolve(provisional)),
              let pending = try? open(in: pane, of: daemon, session: session) else { return }
        // task-owner: one tab creation, then one move of that tab
        Task { [weak self] in
            guard let created = try? await pending.value() else { return }
            let target = ActionTargetRef(kind: .tab, id: created.key)
            _ = self?.actionRegistry?.perform("tab.moveToNewSplit", invocation: ActionInvocation(
                target: target, arguments: ["direction": .string("right")], origin: .user))
        }
    }
}
