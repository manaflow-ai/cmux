import AppKit
import CmuxNextFeed

extension RightSidebarSections {
    /// The app's sections: Vault (the session vault), Feed, Dock (the shown
    /// screen's docked columns) and Cloud (the machines). Files and Find
    /// register from the file explorer.
    func registerAppSections(_ services: AppServices) {
        register(.sessions) { [weak services] _ in
            guard let services else { return NSView() }
            return VaultHostView(vault: services.vault, registry: services.registry)
        }
        register(.feed) { [weak services] _ in
            guard let services else { return NSView() }
            services.feed.startIfSignedIn()
            return FeedHostView(model: services.feed.model)
        }
        register(.dock) { DockSectionHostView(controller: $0) }
        register(.machines) { [weak services] _ in
            guard let services else { return NSView() }
            return MachineSectionHostView(services: services)
        }
    }
}
