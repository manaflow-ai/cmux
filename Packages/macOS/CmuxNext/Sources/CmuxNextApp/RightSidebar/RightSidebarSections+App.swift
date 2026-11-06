import AppKit

extension RightSidebarSections {
    /// The app's sections: Files (the file explorer), Find (its project-wide search), Vault (the session vault),
    /// Feed, Dock (the shown screen's docked columns) and Cloud (the machines).
    /// Each section reads the services of the window it opens in.
    func registerAppSections() {
        register(.files) { $0.services.fileExplorers.makeSection(for: $0) }
        register(.find) { $0.services.fileExplorers.makeFindSection(for: $0) }
        register(.sessions) { VaultHostView(vault: $0.services.vault, registry: $0.services.registry) }
        // The Feed page's list (feed-page.md), as the Feed panel shows it.
        register(.feed) { PageFactory(services: $0.services).feedWebPage(route: "#/list?surface=sidebar") ?? NSView() }
        register(.dock) { DockSectionHostView(controller: $0) }
        register(.machines) { MachineSectionHostView(services: $0.services) }
    }
}
