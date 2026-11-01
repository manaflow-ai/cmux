import AppKit
import CmuxNextActions
import CmuxNextAgentPane

/// App actions on an agent chat's own tab: the header's tools and "..." menu
/// (acpmux header/ChatHeaderTools.tsx), the empty-space right-click menu (`agentChat`
/// placements) and Search the Web on selected text. Kept off `AgentTabStore`, whose wiring is
/// at its type budget.
@MainActor
struct AgentChatTabActions {
    /// The chat's tab now (a provisional id becomes the store's).
    let tab: @MainActor () -> String
    let registry: @MainActor () -> ActionRegistry?
    /// Opens the Files tree of a folder beside the chat (AgentTabStore.openFiles), on tab `target` or in a new column.
    var files: @MainActor (_ folder: String, _ target: String?) -> Void = { _, _ in }
    /// The empty-space menu's rows that don't apply to this chat now (Move to Cloud on a chat of another machine).
    var hidden: @MainActor () -> Set<ActionID> = { [] }
    /// Ghostty's `split-inherit-working-directory` (NewTerminalStart, cx-zld.1).
    var splitInherits: @MainActor () -> Bool = { NewTerminalStart.inherits(.split) }
    /// The chat's folder is on this Mac: the inherit keys apply only here (NewTerminalStart).
    var local: @MainActor () -> Bool = { true }
    /// Opens the header's Terminal or Browser on the chat's right (AgentTabStore.openTool); false when the chat is not shown.
    var openTool: @MainActor (_ kind: RightColumnPlacement.Kind, _ cwd: String?) -> Bool = { _, _ in false }

    /// A header action, with the folder it names when it names one, on the chat's tab or on tab
    /// `target`; the header's Terminal and Browser on the chat's tab go through ``openTool`` first.
    func run(_ id: String, cwd: String?, on target: String? = nil) {
        // The header's Terminal names the chat's folder, the one a split inherits: with Ghostty's
        // `split-inherit-working-directory = false` it names none, and the split starts in the home
        // folder as any split does (PaneHandlers.split, NewTerminalStart). Only for a chat on this Mac:
        // the key is this Mac's, and a chat of another machine keeps its folder.
        let terminal = id == "splitRight" || id == "splitDown"
        let cwd = terminal && local() && !splitInherits() ? nil : cwd
        // Terminal and Browser open on the chat's right as a link does (RightColumnPlacement): a tab in the
        // pane that holds that kind, a split below for the other kind, never a third column (Leo, 2026-10-31).
        if target == nil, let kind = ["splitRight": RightColumnPlacement.Kind.terminal, "splitBrowserRight": .browser][id],
           openTool(kind, cwd) { return }
        let arguments: [String: ActionValue] = cwd.map { ["cwd": .string($0)] } ?? [:]
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target ?? tab()), arguments: arguments, origin: .user)
        // The header's Terminal and Split Down open a terminal, not the New Tab page a person's split from a chat opens.
        invocation.opensTerminal = terminal
        _ = registry()?.perform(ActionID(rawValue: id), invocation: invocation)
    }

    /// Runs `id` (Changes' diff viewer, Preview's browser) where an agent's beside_caller run puts
    /// its tab: in tab `target`'s column, or with no target in a new column right of the chat. A
    /// person clicked it, so the tab takes the focus (``ActionInvocation/besideTakesFocus``).
    func runBeside(_ id: String, arguments: [String: ActionValue], on target: String?) {
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target ?? tab()), arguments: arguments, origin: .user)
        invocation.besideCaller = true
        invocation.newColumnBeside = target == nil
        invocation.besideTakesFocus = true
        _ = registry()?.perform(ActionID(rawValue: id), invocation: invocation)
    }

    /// The header's Files (cx-p4rt): the tree of `folder` beside the chat, as ``runBeside(_:arguments:on:)`` places a diff.
    func openFiles(_ folder: String?, on target: String?) {
        if let folder, !folder.isEmpty { files(folder, target) }
    }

    /// Closes tab `id` (a quick action's split, AgentChatSplitToggles) as its own Close Tab does.
    func close(tab id: String) {
        _ = registry()?.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user))
    }

    /// The "..." menu's Move to Floating Chat: once `float` put session `id` in Start Agent's
    /// panel, the chat's tab closes as its own Close Tab does.
    func moveToFloatingChat(_ id: String, via float: (@MainActor (String) -> Bool)?) -> Bool {
        guard float?(id) == true else { return false }
        close(tab: tab())
        return true
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
        let menu = registry.makeContextMenu(for: .agentChat, target: ActionTargetRef(kind: .tab, id: tab()),
                                            entries: registry.contextMenuEntries(for: .agentChat, removing: hidden()))
        let items = menu.items
        menu.removeAllItems()
        return items
    }
}
