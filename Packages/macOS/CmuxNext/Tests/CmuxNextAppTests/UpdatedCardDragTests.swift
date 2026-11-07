import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-07, on the sidebar's "Updated to Nightly" card: "what if you could, like, drag around
/// the updated to nightly, and you can drag that up to the top if you wanted to?" The card's page runs
/// the drag and reports it; the host stands the card where the page holds it, and once it is let go at
/// the top, rests it under the list's top edge, the list taking the room there and giving back the
/// bottom slot's. The place is kept across launches, so the next sidebar shows the card there at once.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct UpdatedCardDragTests {
    final class FakeIsland: SidebarSurfaceIsland {
        let view = NSView()
        var contentHeight: CGFloat = 0
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        var onDrag: ((SidebarCardDrag) -> Void)?
        var places: [SidebarCardPlace] = []
        func close() {}
        func setPlace(_ place: SidebarCardPlace) { places.append(place) }
        func report(height: CGFloat) {
            contentHeight = height
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
    static let keys = [SidebarUpdatedCardHost.rememberedHeightKey, SidebarUpdatedCardHost.rememberedHeightsKey,
                       SidebarUpdatedCardHost.rememberedAnchorKey]

    static func sidebar() throws -> (SidebarView, FakeIsland) {
        let surfaces = FakeSurfaces()
        let model = SidebarModel(sections: [])
        model.updatedCard = card
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.updateSurfaces = surfaces
        sidebar.updatedCardView.configure(card)
        let island = try #require(surfaces.islands.first)
        island.report(height: 48)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, island)
    }

    @Test func aHeldCardFollowsThePageAndDroppedAtTheTopRestsThereWithTheListUnderIt() throws {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) } }
        let (sidebar, island) = try Self.sidebar()
        let host = sidebar.updatedCardView
        let resting = host.frame
        // The list's frame in the sidebar (its scroll view's own frame is inside the edge fade).
        let list = sidebar.edgeFade.frame
        let bottomPlace = try #require(island.places.last)
        #expect(bottomPlace.anchor == .bottom)
        #expect(bottomPlace.below == 0, "the slot is the lowest place")
        #expect(bottomPlace.above > 300, "the card may be dragged up to the list's top")

        // Held 120 points up: the card stands there, and nothing else moves.
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 4, y: -120)))
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.frame.minY == resting.minY - 120)
        #expect(host.frame.minX == resting.minX + 4)
        #expect(sidebar.edgeFade.frame == list, "a held card moves no row")

        // Let go in the top half: it rests at the top (no window: the springs land at once).
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 4, y: -300), drop: .top))
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.anchor == .top)
        #expect(UserDefaults.standard.string(forKey: SidebarUpdatedCardHost.rememberedAnchorKey) == "top")
        #expect(host.frame.minX == resting.minX)
        // Whole points: the slot's bottom may sit on a half point, the top place does not.
        #expect(abs(host.frame.height - resting.height) <= 1)
        let moved = sidebar.edgeFade.frame
        #expect(host.frame.maxY < moved.minY, "the card stands above the list's rows")
        #expect(moved.minY - list.minY >= host.frame.height, "the list's top makes the card's room")
        #expect(moved.maxY - list.maxY >= host.frame.height, "the bottom slot's room goes back to the list")
        let topPlace = try #require(island.places.last)
        #expect(topPlace.anchor == .top)
        #expect(topPlace.above == 0, "the top place is the highest")
        #expect(topPlace.below > 300)

        // Back down: the bottom slot again, and nothing remembered.
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 0, y: 300), drop: .bottom))
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.frame == resting)
        #expect(sidebar.edgeFade.frame == list)
        #expect(UserDefaults.standard.string(forKey: SidebarUpdatedCardHost.rememberedAnchorKey) == nil)
        host.configure(nil)
    }

    @Test func aCardDroppedAtTheTopShowsThereInTheNextSidebarsFirstFrame() throws {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set("top", forKey: SidebarUpdatedCardHost.rememberedAnchorKey)
        let (sidebar, island) = try Self.sidebar()
        let host = sidebar.updatedCardView
        #expect(host.anchor == .top)
        #expect(host.frame.maxY < sidebar.edgeFade.frame.minY)
        #expect(island.places.last?.anchor == .top)
        host.configure(nil)
    }

    /// Review F2 of #37669: a press while the dropped card is still springing to its place made the
    /// page's offset (0 at the press) the whole displacement, so the card jumped to its rest under the
    /// pointer. The drag carries on from where the card is shown.
    @Test func aDragThatStartsMidSettleCarriesOnFromWhereTheCardIs() throws {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) } }
        let (sidebar, island) = try Self.sidebar()
        let host = sidebar.updatedCardView
        let rest = host.frame
        // Let go a moment ago: the card is still 80 points short of its place.
        host.settleY.catchMidFlight(at: -80, toward: 0)
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 0, y: -1)))
        #expect(host.displaced(rest, in: sidebar).minY == rest.minY - 81, "the card jumped to its rest when the drag began")
        #expect(host.displaced(rest, in: sidebar).minY == rest.minY - 81, "the held card drifts while the page holds it still")

        // Let go back at the bottom: it settles there, and a drag from its rest starts at the rest.
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 0, y: -1), drop: .bottom))
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.frame == rest)
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 0, y: -5)))
        #expect(host.displaced(rest, in: sidebar).minY == rest.minY - 5)
        host.configure(nil)
    }

    /// Review F1 of #37790 at efe59289: the settle started from the frame of the last move the host
    /// processed, not from where the page let the card go, so a release that came between moves (the
    /// page ends a press on a move with no button held) jumped back to the last move before springing.
    @Test func aDropSettlesFromWhereThePageLetTheCardGoNotFromTheLastMove() throws {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) } }
        let (sidebar, island) = try Self.sidebar()
        let host = sidebar.updatedCardView
        let resting = host.frame
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 0, y: -100)))
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.frame.minY == resting.minY - 100)
        // Let go 40 points past the last move, back at the bottom; read where the settle starts before
        // the layout that runs it.
        let relayout = host.onHeightChange
        host.onHeightChange = nil
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 6, y: -140), drop: .bottom))
        #expect(host.droppedAt == CGPoint(x: resting.minX + 6, y: resting.minY - 140))
        host.onHeightChange = relayout
        relayout?()
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.frame == resting)
        host.configure(nil)
    }

    /// Review of #37669 (F1): a card that went away mid-settle came back still springing from the old
    /// drop. Taking the card away resets its settle.
    @Test func aCardTakenAwayMidSettleComesBackAtItsRest() throws {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) } }
        let (sidebar, _) = try Self.sidebar()
        let host = sidebar.updatedCardView
        host.settleX.catchMidFlight(at: 12, toward: 0)
        host.settleY.catchMidFlight(at: -80, toward: 0)
        host.configure(nil)
        #expect(host.settleX.value == 0)
        #expect(host.settleY.value == 0)
    }

    /// Review of #37790 at efe59289 and #37802: a higher-priority card that hid the Updated card mid-drag
    /// left the drag held, so when the card came back the stale offset stood and the page's late release
    /// moved it. Hiding the card ends its drag; the page's moves and release for that press are dropped.
    @Test func aCardHiddenMidDragDropsThatDrag() throws {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) } }
        let (sidebar, island) = try Self.sidebar()
        let host = sidebar.updatedCardView
        let resting = host.frame
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 0, y: -120)))
        sidebar.layoutSubtreeIfNeeded()
        host.isHidden = true
        #expect(host.heldOffset == nil)
        host.isHidden = false
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 0, y: -130)))
        #expect(host.heldOffset == nil, "a late move of the hidden drag")
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 0, y: -300), drop: .top))
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.anchor == .bottom, "the late release of the hidden drag")
        #expect(UserDefaults.standard.string(forKey: SidebarUpdatedCardHost.rememberedAnchorKey) == nil)
        #expect(host.frame == resting)
        // The next press drags.
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 0, y: -10)))
        #expect(host.heldOffset == CGPoint(x: 0, y: -10))
        host.configure(nil)
    }

    /// Review of #38020 at c4dbe0f3: a card taken away while hidden mid-drag kept dropping the page's
    /// drag messages, so when it came back the first move of its next drag was lost.
    @Test func aCardTakenAwayWhileHiddenMidDragDragsWhenItComesBack() throws {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) } }
        let (sidebar, island) = try Self.sidebar()
        let host = sidebar.updatedCardView
        island.onDrag?(SidebarCardDrag(offset: CGPoint(x: 0, y: -120)))
        host.isHidden = true
        host.configure(nil)
        host.configure(Self.card)
        let again = try #require(host.island as? FakeIsland)
        again.onDrag?(SidebarCardDrag(offset: CGPoint(x: 0, y: -10)))
        #expect(host.heldOffset == CGPoint(x: 0, y: -10))
        host.configure(nil)
    }

    /// Through the App's real island and page provider: the page's drag reaches the host in points,
    /// and the host's place reaches the page.
    @Test func theAppsIslandCarriesTheDragAndThePlace() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let island = UpdateSurfaceIsland(kind: .updated, services: services)
        defer { island.close() }
        var drags: [SidebarCardDrag] = []
        island.onDrag = { drags.append($0) }
        let context = PageCallContext(page: PageDescriptor.changelog.id)
        _ = try await island.provider.card.call("cmux.changelog.surface.card.drag",
                                                params: .object(["x": .number(0), "y": .number(-40)]), context: context)
        _ = try await island.provider.card.call("cmux.changelog.surface.card.drag",
                                                params: .object(["x": .number(0), "y": .number(-200), "anchor": .string("top")]),
                                                context: context)
        #expect(drags.count == 2)
        #expect(drags.first?.drop == nil)
        #expect(drags.last?.drop == .top)
        #expect((drags.first?.offset.y ?? 0) <= -40, "CSS px at the page's zoom, in points")

        var places: [JSONValue] = []
        let subscription = try await island.provider.card.subscribe("cmux.changelog.surface.card.place", filter: .object([:]),
                                                                    context: context) { places.append($0) }
        island.setPlace(SidebarCardPlace(anchor: .bottom, above: 400, below: 0))
        island.setPlace(SidebarCardPlace(anchor: .bottom, above: 400, below: 0))
        #expect(places.count == 1, "an unchanged place is not sent again")
        #expect(places.first?["anchor"]?.stringValue == "bottom")
        // Review F3 of #37790: the page reads the pointer's screen deltas in CSS px at this zoom.
        #expect(places.first?["zoom"]?.doubleValue == Double(island.provider.card.zoom()))
        subscription.cancel()
    }
}
