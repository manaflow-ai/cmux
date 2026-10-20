package import CmuxNextActions
package import Foundation

/// Routes Toggle Right Sidebar to the focused chat or its nearest visible neighbor.
@MainActor
package struct AgentChatSideColumn {
    package init() {}

    /// Toggle Right Sidebar for `invocation`; the app binds it (ActionRegistry `run:`).
    package func toggle<Pane>(_ invocation: ActionInvocation, unavailable: () -> String,
                              focused: (ActionInvocation) -> Pane?, panes: () -> [Pane],
                              chat: (Pane) -> AgentPaneView?, left: (Pane) -> CGFloat,
                              refuse: (String) -> Void, fallback: (ActionInvocation) throws -> Void) rethrows {
        guard AgentPaneTunables.sideColumn.value else { return try fallback(invocation) }
        let focused = focused(invocation)
        // A chat's own view: never a New Tab page (the side column's tiles).
        if let focused, let view = chat(focused) { return view.toggleSideColumn() }
        // The nearest chat on the left, else the leftmost on screen, by where panes sit.
        let chats = panes().filter { chat($0) != nil }.sorted { left($0) < left($1) }
        let edge = focused.map(left) ?? .greatestFiniteMagnitude
        guard let pane = chats.last(where: { left($0) < edge }) ?? chats.first, let view = chat(pane) else {
            return refuse(unavailable())
        }
        view.toggleSideColumn()
    }
}
