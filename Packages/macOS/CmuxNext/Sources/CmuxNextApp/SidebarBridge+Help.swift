import AppKit
import CmuxNextActions
import CmuxNextSidebar

enum SidebarHelpMenuProvider {
    static func install(on sidebar: SidebarView, services: AppServices) {
        sidebar.helpMenuProvider = { [weak services] in
            guard let services else { return nil }
            let menu = NSMenu()
            for item in services.registry.makeMainMenuItems(for: .help) {
                menu.addItem(item)
            }
            return menu
        }
    }
}
