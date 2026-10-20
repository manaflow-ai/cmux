import AppKit
import CmuxNextFeed

extension RightSidebarSections {
    /// The app's sections: Vault (the session vault), Feed, Dock (the shown
    /// screen's docked columns) and Cloud (the machines). Files and Find
    /// register from the file explorer.
    func registerAppSections(_ services: AppServices) {
        register(.sessions) { [unowned services] _ in VaultHostView(vault: services.vault, registry: services.registry) }
        register(.feed) { [unowned services] _ in
            services.feed.startIfSignedIn()
            return FeedHostView(model: services.feed.model)
        }
        register(.dock) { DockSectionHostView(controller: $0) }
        register(.machines) { [unowned services] _ in MachineSectionHostView(services: services) }
    }
}
