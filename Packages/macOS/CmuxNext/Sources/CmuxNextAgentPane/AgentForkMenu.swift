import AppKit
import CmuxNextActions

/// Destination choices are secondary to the one-step Fork action on every surface.
@MainActor enum AgentForkMenu {
    static var title: String {
        ActionCatalog.all.first { $0.id == "palette.forkAgentConversationTo" }?.title ?? ""
    }

    static let destinations: [(AgentForkDestination, ActionID)] = [
        (.right, "palette.forkAgentConversationRight"), (.left, "palette.forkAgentConversationLeft"),
        (.up, "palette.forkAgentConversationTop"), (.down, "palette.forkAgentConversationBottom"),
        (.tab, "palette.forkAgentConversationNewTab"), (.workspace, "palette.forkAgentConversationNewWorkspace"),
        (.window, "palette.forkAgentConversationNewWindow"),
    ]

    static func menu(perform: @escaping (AgentForkDestination) -> Void) -> NSMenu {
        let menu = NSMenu(title: title)
        for (destination, id) in destinations {
            guard let action = ActionCatalog.all.first(where: { $0.id == id }) else { continue }
            menu.addItem(AgentPaneMenuAction.item(action.title, symbol: action.symbol) {
                perform(destination)
            })
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
