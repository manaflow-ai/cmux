import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSidebar
import Testing

/// The sidebar's update card is a `privileged` page opened and ended through the app's
/// WebUIHost. No page exists while there is no update, the card's page joins the page lifecycle under
/// its own key, and the dismissed card's page leaves the host and the lifecycle.
@MainActor
@Suite(.serialized)
struct UpdateSurfacePageTests {
    @Test func theCardIsAppContentInThePrivilegedGroup() {
        let card = PageDescriptor.updateSurface
        #expect(card.processGroup == .privileged)
        #expect(card.id == PageDescriptor.changelog.id && card.resource == PageDescriptor.changelog.resource,
                "the card is the changelog bundle on its own origin")
        let capability = PageCapability(card)
        #expect(capability.capabilityClass == .appContent, "\(capability.summary)")
        var groups = PageProcessGroupTableTests.groups
        groups[.privileged, default: []].append(card)
        let audit = PageProcessGroupTableTests.audit(groups)
        #expect(audit.violations.isEmpty, "\(audit.report)")
    }

    /// The table admits the surface's own ops and the notes the card reads, and nothing the
    /// changelog tab has beyond them (its link card, its Try it).
    @Test func theCardAdmitsOnlyTheOpsItUses() throws {
        let card = PageDescriptor.updateSurface
        let table = try #require(card.opTable(for: "cmux.changelog."))
        let surface = Set(table.kinds.keys.filter { $0.hasPrefix("cmux.changelog.surface.") })
        #expect(surface == [UpdateSurfaceProvider.getOp, UpdateSurfaceProvider.sizeOp, UpdateSurfaceProvider.openChangelogOp,
                            UpdateSurfaceProvider.dismissOp, UpdateSurfaceProvider.changesStream])
        for op in ["cmux.changelog.list", "cmux.changelog.get", "cmux.changelog.reel"] {
            #expect(card.admits(op), "\(op)")
        }
        for op in ["cmux.changelog.pr.inspect", "cmux.changelog.browser.list", "cmux.changelog.browser.openIn", PageNativeOp.actionRun] {
            #expect(!card.admits(op), "\(op)")
        }
    }

    @Test func noPageWithoutAnUpdateAndTheDismissedCardsPageIsClosed() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let lifecycle = PageLifecycle(deadlines: services.mainDeadlines)
        services.webUI.lifecycle = lifecycle
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.updateSurfaces = UpdateSurfaceIslands(services: services)
        func cardPages() -> [PageWebView] { services.webUI.openPages.filter { $0.descriptor == .updateSurface } }

        #expect(cardPages().isEmpty, "no update: no page")
        #expect(sidebar.updatedCardView.island == nil && sidebar.updateCardView.highlights == nil)

        sidebar.updatedCardView.configure(SidebarUpdatedCard(title: "Updated", whatsNewTitle: "See What's New", dismissLabel: "Close"))
        let island = try #require(sidebar.updatedCardView.island as? UpdateSurfaceIsland)
        let page = try #require(island.page, "the card opens its page through the host")
        let key = try #require(island.lifecycleKey)
        #expect(cardPages().map(ObjectIdentifier.init) == [ObjectIdentifier(page)])
        #expect(lifecycle.state(of: key) == .active, "the shown card's page is in the lifecycle under its own key")

        // The x sends `.dismissUpdated`; the feed then takes the card away.
        sidebar.updatedCardView.configure(nil)
        #expect(cardPages().isEmpty, "the dismissed card's page leaves the host")
        #expect(lifecycle.state(of: key) == nil, "and the lifecycle")
        #expect(services.webUI.registry.pages(id: PageDescriptor.updateSurface.id).allSatisfy { $0 !== page })
    }
}
