import AppKit
import CmuxNextActions
import CmuxNextApps
@testable import CmuxNextApp
import CmuxNextPages
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The Machines page has a home again (its right sidebar went in #41025, and nothing made
/// `MachineSectionHostView` since): one "Machines" sidebar item that opens the page on top, off by
/// default (Add to Sidebar and the App Store's "Machines in Sidebar" add it, removing it restores the
/// sidebar as it was), and `machines.show` in Cmd+Shift+P. The page is the Machines section's own host.
@MainActor
struct MachinesEntryTests {
    @Test func theSidebarItemOpensTheMachinesTopPageAndIsOffByDefault() {
        #expect(SidebarBuiltIn(rawValue: "machines") == .machines)
        #expect(SidebarBridge.builtInActions[.machines] == "machines.show")
        #expect(TopPageRoute.route(for: .builtIn(.machines)) == .page(.machines))
        #expect(TopPageRoute(rawValue: TopPageRoute.page(.machines).rawValue) == .page(.machines))
        #expect(SidebarLayoutDocument.defaults.firstItem(with: .builtIn(.machines)) == nil)
        #expect(!SidebarBuiltIn.machines.title.isEmpty)
        #expect(SidebarBuiltIn.machines.icon == .machine)
    }

    /// The setting: the App Store's sidebar card, listed with the other sidebar items (its on state is
    /// whether the sidebar holds the item, so the default sidebar stays as it is). `machines.show` in
    /// Cmd+Shift+P and Add to Sidebar's "Machines" come from the Rust catalog with the next app FFI
    /// re-pin (AWAITING_REPIN in cmux-action-catalog's swift_parity.rs); their checks land with it.
    @Test func theAppStoreOffersIt() throws {
        let feature = try #require(AppFeature.catalog.first { $0.id == "machines.sidebarItem" })
        #expect(feature.on == .sidebarItem("machines"))
        #expect(feature.setting == "sidebar.layout")
    }

    /// The page's provider makes the Machines section's host, which loads `cmux-page://cmux.machines/`.
    @Test func thePageProviderHostsTheMachinesPage() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        TopPages.registerMachines(services)
        let provider = try #require(services.pages.provider(.machines))
        #expect(provider.title == SidebarBuiltIn.machines.title)
        let view = provider.makeView(for: LocalPageTab.makeKey(.machines), in: nil)
        let host = try #require(view as? MachineSectionHostView)
        #expect(host.section is PageSectionHost)
    }
}
