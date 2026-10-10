import AppKit
import CmuxNextActions

/// App actions on an agent chat's own tab: the header's tools and "..." menu
/// (acpmux header/ChatHeaderTools.tsx), the empty-space right-click menu (`agentChat`
/// placements) and Search the Web on selected text. Kept off `AgentTabStore`, whose wiring is
/// at its type budget.
@MainActor
struct AgentChatTabActions {
    /// The chat's tab now (a provisional id becomes the store's).
    let tab: @MainActor () -> String
    let registry: @MainActor () -> ActionRegistry?

    /// A header action, with the folder it names when it names one, on the chat's tab or on tab
    /// `target` (a header split opening right of the one before it, AgentChatSplitToggles).
    func run(_ id: String, cwd: String?, on target: String? = nil) {
        let arguments: [String: ActionValue] = cwd.map { ["cwd": .string($0)] } ?? [:]
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target ?? tab()), arguments: arguments, origin: .user)
        // The header's Terminal opens a terminal, not the New Tab page a person's Split Right from a chat opens.
        invocation.opensTerminal = id == "splitRight"
        _ = registry()?.perform(ActionID(rawValue: id), invocation: invocation)
    }

    /// Runs `id` (the diff viewer, Changes) as an agent's beside_caller run, keeping focus in the
    /// chat: its tab opens selected in tab `target`'s column, or with no target in a new column right
    /// of the chat; `path` names the repository.
    func runBeside(_ id: String, path: String?, on target: String?) {
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target ?? tab()),
                                          arguments: path.map { ["path": .string($0)] } ?? [:], origin: .user)
        invocation.besideCaller = true
        invocation.newColumnBeside = target == nil
        _ = registry()?.perform(ActionID(rawValue: id), invocation: invocation)
    }

    /// Closes tab `id` (a quick action's split, AgentChatSplitToggles) as its own Close Tab does.
    func close(tab id: String) {
        _ = registry()?.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user))
    }

    /// Search the Web on selected chat text: a browser tab beside the chat, with the omnibar's
    /// search engine.
    func searchWeb(_ text: String) {
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab()), arguments: ["text": .string(text)], origin: .user)
        _ = registry()?.perform("browser.selection.search", invocation: invocation)
    }

    /// The empty-space menu's items, detached for the pane's menu to take.
    func menuItems() -> [NSMenuItem] {
        guard let registry = registry() else { return [] }
        let menu = registry.makeContextMenu(for: .agentChat, target: ActionTargetRef(kind: .tab, id: tab()))
        let items = menu.items
        menu.removeAllItems()
        return items
    }
}
