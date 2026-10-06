import AppKit
import CmuxNextActions

extension SidebarBridge {
    func configureHelpMenu() {
        container.sidebarView.helpMenuProvider = { [weak services] in
            guard let services else { return nil }
            let menu = NSMenu()
            for item in services.registry.makeMainMenuItems(for: .help) {
                menu.addItem(item)
            }
            return menu
        }
    }
}
