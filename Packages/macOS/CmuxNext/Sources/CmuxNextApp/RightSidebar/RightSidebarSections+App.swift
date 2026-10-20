import AppKit
import CmuxNextFeed

extension RightSidebarSections {
    /// The app's sections: Vault (the session vault), Feed, Dock (the shown
    /// screen's docked columns) and Cloud (the machines). Files and Find
    /// register from the file explorer.
    /// Each section reads the services of the window it opens in.
    func registerAppSections() {
        register(.sessions) { VaultHostView(vault: $0.services.vault, registry: $0.services.registry) }
        register(.feed) { controller in
            controller.services.feed.startIfSignedIn()
            return FeedHostView(model: controller.services.feed.model)
        }
        register(.dock) { DockSectionHostView(controller: $0) }
        register(.machines) { MachineSectionHostView(services: $0.services) }
    }
}
