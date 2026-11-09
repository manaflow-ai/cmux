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
        var previewHeight: CGFloat = 0
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        var pointer: [Bool] = []
        func close() {}
        func setPointerInside(_ inside: Bool) { pointer.append(inside) }
        func report(height: CGFloat, overlay: CGFloat, preview: CGFloat = 0) {
            (contentHeight, overlayHeight, previewHeight) = (height, overlay, preview)
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
        // Whole points: a slot bottom on a half point rounds the 48 out to 49.
        #expect(resting.height >= 48 && resting.height <= 49)

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

    /// Leo 2026-11-08: "it turns from glass when it's unhovered into opaque when it does get hovered"
    /// and "the cursor propagates to, like, the actual workspace stuff on the sidebar". The host draws
    /// the card's glass behind the page, the card's size and its open preview's on the card's bottom
    /// edge; the rows under that glass light nothing and open no card, and the room the view keeps
    /// past the glass (asked for before the preview opens, or kept while it closes) passes the pointer on.
    @Test func theOpenPreviewsGlassCoversTheRowsUnderItAndOwnsThePointer() throws {
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
        island.report(height: 48, overlay: 0)
        sidebar.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        #expect(!host.glass.isHidden, "the resting card has its glass too: nothing swaps when the preview opens")
        #expect(host.glass.frame == host.bounds)
        #expect(host.glass.superview === host && host.subviews.first === host.glass, "the glass is under the page")

        // The room first (the page waits for it), then the preview opens to 200 of rows.
        island.report(height: 48, overlay: 248)
        sidebar.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        #expect(host.glassFrame.height == 48, "the room alone grows no glass")
        let roomTop = sidebar.convert(NSPoint(x: host.frame.midX, y: host.frame.maxY - 100), to: nil)
        #expect(!host.covers(windowPoint: roomTop))
        #expect(host.hitTest(host.superview!.convert(roomTop, from: nil)) == nil, "the room past the glass takes no click")

        island.report(height: 48, overlay: 248, preview: 200)
        host.layoutSubtreeIfNeeded()
        #expect(host.glassFrame == host.bounds, "the glass is the card and its open preview")
        #expect(host.covers(windowPoint: roomTop), "over the open preview the rows under it light nothing")
        #expect(sidebar.list.hoverOccluded?(roomTop) == true, "the list asks the card before it lights a row")
        let below = sidebar.convert(NSPoint(x: host.frame.midX, y: host.frame.maxY + 40), to: nil)
        #expect(sidebar.list.hoverOccluded?(below) != true, "past the card the rows hover as before")

        // The close starts: the glass goes with the page's preview, before the room goes back.
        island.report(height: 48, overlay: 248, preview: 0)
        host.layoutSubtreeIfNeeded()
        #expect(host.glassFrame.height == 48)
        #expect(!host.covers(windowPoint: roomTop))
        host.configure(nil)
        #expect(!host.covers(windowPoint: roomTop), "a dismissed card covers nothing")
    }

    /// Review F1 of #37615: builds before the composer-height card remembered its taller two-line
    /// heights (64 and 77 pt) under the old keys. After the upgrade those heights are no guess for the
    /// 48 pt card: its first frame does not hold them, and the page's 48 is the card's height.
    @Test func heightsRememberedByTheTallerCardAreNotHeldAfterTheUpgrade() throws {
        let legacy = ["cmux.sidebar.updatedCard.height", "cmux.sidebar.updatedCard.heights"]
        let keys = legacy + [SidebarUpdatedCardHost.rememberedHeightKey, SidebarUpdatedCardHost.rememberedHeightsKey]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        UserDefaults.standard.set(77.0, forKey: legacy[0])
        UserDefaults.standard.set((150...300).map { [Double($0), 77.0] }, forKey: legacy[1])
        let surfaces = FakeSurfaces()
        let model = SidebarModel(sections: [])
        model.updatedCard = Self.card
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.updateSurfaces = surfaces
        let host = sidebar.updatedCardView
        host.configure(Self.card)
        let island = try #require(surfaces.islands.first)
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.heldHeight == 0, "the first frame holds no height the old card remembered")
        island.report(height: 48, overlay: 0)
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.height == 48)
        #expect(host.frame.height >= 48 && host.frame.height <= 49)
        host.configure(nil)
    }

    /// Review F3 of #37615: a card of higher priority (here Now Playing) takes the slot while the
    /// preview is open. The hidden card is no longer under the pointer: its x hides and the page hears
    /// the pointer leave, so it closes the preview and hands the room back, and the card comes back
    /// closed when the slot is its again.
    @Test func aCardHiddenByTheSlotTellsThePageThePointerLeft() throws {
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
        island.report(height: 48, overlay: 0)
        sidebar.layoutSubtreeIfNeeded()
        #expect(!host.isHidden)

        host.setHovered(true)
        island.report(height: 48, overlay: 248)
        sidebar.layoutSubtreeIfNeeded()
        #expect(island.pointer == [true])

        let labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous", next: "Next")
        sidebar.nowPlayingCardView.configure(SidebarNowPlaying(title: "Weightless", isPlaying: true, labels: labels))
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.isHidden, "Now Playing has the slot")
        #expect(island.pointer == [true, false], "the page hears the pointer leave the hidden card")
        #expect(!host.isHovered)
        #expect(!host.closeShown, "the hidden card's x does not come back with it")

        sidebar.nowPlayingCardView.configure(nil)
        island.report(height: 48, overlay: 0)
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(!host.isHidden)
        #expect(island.pointer == [true, false], "the card comes back closed until the pointer moves onto it")
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

    /// Leo 2026-11-08: "flicker upon hovering over what's new". The host's hover is where the pointer is
    /// now: the open preview handing its room back under a still pointer ends the hover once, and the
    /// room above the glass never counts. A tracking area on the whole view sent no exit when it shrank,
    /// so the page kept hearing "inside" over the rows and opened the list again.
    @Test func theHoverEndsWhenTheRoomGoesBackUnderAStillPointer() throws {
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
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer {
            PointerHover.setDebugPointer(nil, in: window)
            window.close()
        }
        sidebar.updateSurfaces = surfaces
        let host = sidebar.updatedCardView
        host.configure(Self.card)
        let island = try #require(surfaces.islands.first)
        island.report(height: 48, overlay: 0)
        sidebar.layoutSubtreeIfNeeded()
        let card = host.convert(host.bounds, to: nil)
        PointerHover.setDebugPointer(NSPoint(x: card.midX, y: card.midY), in: window)
        #expect(host.isHovered, "the pointer on the card")

        // The view grows for the room before the page opens: the room alone is not the card.
        island.report(height: 48, overlay: 248)
        sidebar.layoutSubtreeIfNeeded()
        let above = NSPoint(x: card.midX, y: card.maxY + 100)
        PointerHover.setDebugPointer(above, in: window)
        #expect(!host.isHovered, "the room asked for before the preview opens is not the card")

        // Open: the glass reaches the pointer.
        island.report(height: 48, overlay: 248, preview: 200)
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.isHovered, "the open preview's glass is the card")

        // The page closes and hands the room back while the pointer stays put, over the rows now.
        island.report(height: 48, overlay: 0, preview: 0)
        sidebar.layoutSubtreeIfNeeded()
        #expect(!host.isHovered, "the room gone from under a still pointer ends the hover")
        #expect(island.pointer.last == false, "the page hears it, so it does not open the list again")
        host.configure(nil)
    }
}
