import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSidebar
import Testing

/// u2441 (2026-10-19): the "Updated to nightly …" card's x lives in its React page. Every
/// bottom-left card's x sends one sidebar intent (the notice card's `.dismissNotice`, the media
/// card's `.hideNowPlayingCard`), which the App routes through `SidebarCardFeed.handle`. The page's
/// x called the updater directly, a second path. Through the real host bridge (the sidebar's card
/// host, the App's island and its page provider), the page's dismiss reaches the sidebar as
/// `.dismissUpdated`.
@MainActor
@Suite(.serialized)
struct UpdatedCardDismissPathTests {
    @Test func thePagesXSendsTheSidebarsDismissIntent() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let model = SidebarModel(sections: [])
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.updateSurfaces = UpdateSurfaceIslands(services: services)
        sidebar.updatedCardView.configure(SidebarUpdatedCard(title: "Updated", whatsNewTitle: "See What's New", dismissLabel: "Close"))
        let island = try #require(sidebar.updatedCardView.island as? UpdateSurfaceIsland, "the card mounts the App's page")

        _ = try await island.provider.call("cmux.changelog.surface.dismiss", params: .object([:]),
                                           context: PageCallContext(page: PageDescriptor.changelog.id))

        #expect(intents == [.dismissUpdated], "the x goes through the sidebar's one card-dismiss path")
        sidebar.updatedCardView.configure(nil)
    }

    /// Lawrence 2026-10-23: "i cant X this out anymore even when hovering on it". The x was the
    /// page's own button; WebKit shows no hover and eats the first click while another of the
    /// app's windows (a Chromium page's) has the key. The host's native x shows on the pointer's
    /// entry, takes a first click in a window that is not key, and sends `.dismissUpdated`.
    @Test func theNativeXShowsOnHoverTakesTheFirstClickAndDismisses() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let model = SidebarModel(sections: [])
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.updateSurfaces = UpdateSurfaceIslands(services: services)
        let host = sidebar.updatedCardView
        host.configure(SidebarUpdatedCard(title: "Updated", whatsNewTitle: "See What's New", dismissLabel: "Close"))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
        host.layoutSubtreeIfNeeded()

        #expect(!host.closeShown, "the x waits for the pointer")
        host.setHovered(true)
        #expect(host.closeShown, "the pointer on the card shows the x")
        #expect(host.closeButton.accessibilityLabel() == "Close")
        #expect(host.closeButton.frame.maxX == 200 - SidebarUpdatedCardHost.closeInset.width, "the x sits at the card's top right")
        #expect(host.subviews.last === host.closeButton, "the page never covers the x")
        #expect(host.closeButton.acceptsFirstMouse(for: nil), "a first click in a window that is not key presses the x")

        host.closeButton.performClick(nil)
        #expect(intents == [.dismissUpdated], "the x goes through the sidebar's one card-dismiss path")

        host.configure(nil)
        #expect(!host.closeShown, "a card that comes back waits for the pointer again")
    }
}
