import AppKit
import CmuxNextActions

/// Destination choices are secondary to the one-step Fork action on every surface.
@MainActor enum AgentForkMenu {
    static var title: String {
        ActionCatalog.all.first { $0.id == "palette.forkAgentConversationTo" }?.title ?? ""
    }

    static let destinations: [(AgentForkDestination, ActionID)] = AgentForkDestination.allCases.map { ($0, $0.actionID) }

    /// The submenu's sections, split by separators so ten rows stay easy to scan (u18673): a split
    /// beside the chat, a new strip column or row, then somewhere else (tab, workspace, window).
    static let groups: [[AgentForkDestination]] = [
        [.right, .left, .up, .down], [.columnRight, .columnLeft, .row], [.tab, .workspace, .window],
    ]

    static func menu(perform: @escaping (AgentForkDestination) -> Void) -> NSMenu {
        let menu = NSMenu(title: title)
        for group in groups {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            for destination in group {
                guard let id = destinations.first(where: { $0.0 == destination })?.1,
                      let action = ActionCatalog.all.first(where: { $0.id == id }) else { continue }
                menu.addItem(AgentPaneMenuAction.item(action.title, symbol: action.symbol) {
                    perform(destination)
                })
            }
        }
        return menu
    }

    static func item(perform: @escaping (AgentForkDestination) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = AgentPaneContextMenu.icon("arrow.triangle.branch")
        item.submenu = menu(perform: perform)
        return item
    }
}
