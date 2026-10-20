package import CmuxNextActions
package import Foundation

/// Routes Toggle Right Sidebar to the focused chat or its nearest visible neighbor.
@MainActor
package struct AgentChatSideColumn {
    package init() {}

    package func bind<Pane>(into registry: ActionRegistry, unavailable: @escaping @MainActor () -> String,
                            focused: @escaping @MainActor (ActionInvocation) -> Pane?,
                            panes: @escaping @MainActor () -> [Pane],
                            chat: @escaping @MainActor (Pane) -> AgentPaneView?,
                            left: @escaping @MainActor (Pane) -> CGFloat,
                            refuse: @escaping @MainActor (String) -> Void,
                            fallback: @escaping @MainActor (ActionInvocation) throws -> Void) {
        registry.bind("toggleRightSidebar", run: { invocation in
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
        })
    }
}
