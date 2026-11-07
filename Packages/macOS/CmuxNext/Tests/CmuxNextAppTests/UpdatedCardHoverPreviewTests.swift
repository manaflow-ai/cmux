import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-07, on the sidebar's "Updated to Nightly" card: "you hover over it and you get to, like,
/// scroll through the thing if you want" / "Right in that bottom left of the sidebar area". The card's
/// page opens its hover preview and asks for the room above the card; the host tells the page where the
/// pointer is, and grows its view upward over the list by that room, with the list, the slot and the x
/// where they were. Once the preview has closed the view is the card again.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct UpdatedCardHoverPreviewTests {
    final class FakeIsland: SidebarSurfaceIsland {
        let view = NSView()
        var contentHeight: CGFloat = 0
        var overlayHeight: CGFloat = 0
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        var pointer: [Bool] = []
        func close() {}
        func setPointerInside(_ inside: Bool) { pointer.append(inside) }
        func report(height: CGFloat, overlay: CGFloat) {
            (contentHeight, overlayHeight) = (height, overlay)
            onHeightChange?()
        }
    }

    final class FakeSurfaces: SidebarUpdateSurfaces {
        var islands: [FakeIsland] = []
        func island(_ kind: SidebarUpdateSurfaceKind) -> any SidebarSurfaceIsland {
            let island = FakeIsland()
            islands.append(island)
            return island
        }
    }

    static let card = SidebarUpdatedCard(title: "Updated", whatsNewTitle: "What's New", dismissLabel: "Close")

    @Test func theOpenPreviewGrowsTheCardUpwardOverTheListWithoutMovingIt() throws {
        UserDefaults.standard.removeObject(forKey: SidebarUpdatedCardHost.rememberedHeightKey)
        UserDefaults.standard.removeObject(forKey: SidebarUpdatedCardHost.rememberedHeightsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: SidebarUpdatedCardHost.rememberedHeightKey)
            UserDefaults.standard.removeObject(forKey: SidebarUpdatedCardHost.rememberedHeightsKey)
        }
        let surfaces = FakeSurfaces()
        let model = SidebarModel(sections: [])
        model.updatedCard = Self.card
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.updateSurfaces = surfaces
        let host = sidebar.updatedCardView
        host.configure(Self.card)
        let island = try #require(surfaces.islands.first)
        // The composer's one-line height.
        island.report(height: 48, overlay: 0)
        sidebar.layoutSubtreeIfNeeded()
        let resting = host.frame
        let listBottom = sidebar.scrollView.frame.minY
        let closeOnScreen = host.convert(host.closeButton.frame, to: sidebar)
        #expect(resting.height == 48)

        host.setHovered(true)
        #expect(island.pointer == [true], "the page hears the pointer from the host's tracking area")

        // The page opens its preview: 48 of card and 200 of rows.
        island.report(height: 48, overlay: 248)
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.frame.maxY == resting.maxY, "the card's bottom edge stays on its slot")
        #expect(host.frame.height == 248, "the view grows upward by the preview's room")
        #expect(sidebar.scrollView.frame.minY == listBottom, "the list keeps its room: the preview stands over it")
        #expect(host.convert(host.closeButton.frame, to: sidebar) == closeOnScreen, "the x stays on the card's title line")

        host.setHovered(false)
        #expect(island.pointer == [true, false])
        island.report(height: 48, overlay: 0)
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.frame == resting, "a closed preview gives the room back")
        host.configure(nil)
    }

    /// Through the App's real island and page provider: the page hears the pointer (now, then each
    /// change) and the room its preview asks for reaches the host.
    @Test func theAppsIslandStreamsThePointerAndTakesThePreviewsRoom() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let island = UpdateSurfaceIsland(kind: .updated, services: services)
        defer { island.close() }
        var events: [JSONValue] = []
        let context = PageCallContext(page: PageDescriptor.changelog.id)
        let subscription = try await island.provider.subscribe("cmux.changelog.surface.pointer", filter: .object([:]),
                                                               context: context) { events.append($0) }
        island.setPointerInside(true)
        island.setPointerInside(true)
        island.setPointerInside(false)
        #expect(events == [.object(["inside": .bool(false)]), .object(["inside": .bool(true)]), .object(["inside": .bool(false)])])
        subscription.cancel()
        island.setPointerInside(true)
        #expect(events.count == 3, "a cancelled subscription hears nothing more")

        var changes = 0
        island.onHeightChange = { changes += 1 }
        _ = try await island.provider.call("cmux.changelog.surface.size",
                                           params: .object(["height": .number(48), "width": .number(0), "overlay": .number(248)]),
                                           context: context)
        #expect(changes == 1)
        #expect(island.overlayHeight >= 248, "the preview's room reaches the host (in points, at the page's zoom)")
        #expect(island.contentHeight >= 48)
    }
}
