import AppKit
import CmuxNextActions
import CmuxNextAgentPane

/// The chat header's tools and "..." menu (acpmux header/ChatHeaderTools.tsx) and the chat's
/// empty-space right-click menu: app actions on the chat's own tab, and the tab state the
/// menu's labels read.
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
            }
        )
        model.chatMenuItems = { [weak self] in
            guard let self, let actionRegistry else { return [] }
            let target = ActionTargetRef(kind: .tab, id: resolve(provisional))
            let menu = actionRegistry.makeContextMenu(for: .agentChat, target: target)
            let items = menu.items
            menu.removeAllItems()
            return items
        }
    }
}
