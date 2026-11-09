import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The Updated card's first-frame hold (``SidebarUpdatedCardHost/heldHeight``) is in points at the
/// interface scale it was taken at. A live scale decrease shrinks the page's height, and the hold must
/// shrink with it: a card held at 60 points at 125% is 48 at 100%, not stuck at 60 (review of #38107).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct UpdatedCardScaleDownTests {
    final class FakeIsland: SidebarSurfaceIsland {
        let view = NSView()
        var contentHeight: CGFloat = 0
        var overlayHeight: CGFloat = 0
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        func close() {}
        func setPointerInside(_ inside: Bool) {}
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

    @Test func aScaleDecreaseShrinksTheHeldCard() throws {
        let keys = [SidebarUpdatedCardHost.rememberedHeightKey, SidebarUpdatedCardHost.rememberedHeightsKey]
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        let design = DesignSettings.shared
        let saved = design.uiScale
        design.uiScale = 1.25
        defer {
            design.uiScale = saved
            keys.forEach(UserDefaults.standard.removeObject(forKey:))
        }
        let surfaces = FakeSurfaces()
        let model = SidebarModel(sections: [])
        model.updatedCard = Self.card
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.updateSurfaces = surfaces
        let host = sidebar.updatedCardView
        // A first showing at 125% remembers its 60 points at this width.
        host.configure(Self.card)
        sidebar.layoutSubtreeIfNeeded()
        try #require(surfaces.islands.last).report(height: 60)
        sidebar.layoutSubtreeIfNeeded()
        host.configure(nil)

        // The next showing holds those 60 points from its first frame.
        host.configure(Self.card)
        sidebar.layoutSubtreeIfNeeded()
        let island = try #require(surfaces.islands.last)
        island.report(height: 60)
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.heldHeight == 60)
        #expect(host.height == 60)

        // The scale goes down to 100%: the page's 48 px card is 48 points, and the hold follows it.
        design.uiScale = 1
        island.report(height: 48)
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.height == 48, "the card kept \(host.height) points at 100%")
        #expect(host.frame.height <= 49, "the card's frame kept \(host.frame.height) points at 100%")
    }

    /// A sidebar for the card at `scale` (the caller puts the scale and the remembered heights back).
    private func sidebarAtScale(_ scale: CGFloat) -> (SidebarView, FakeSurfaces) {
        let surfaces = FakeSurfaces()
        let model = SidebarModel(sections: [])
        model.updatedCard = Self.card
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.updateSurfaces = surfaces
        DesignSettings.shared.uiScale = scale
        return (sidebar, surfaces)
    }

    /// Review F1 of #38150: the remembered height is kept free of the scale it was reported at, so a
    /// 60 pt card remembered at 125% is held at 48 the next launch at 100%, not at 60.
    @Test func aRememberedHeightKeepsItsScaleAcrossLaunches() throws {
        let keys = [SidebarUpdatedCardHost.rememberedHeightKey, SidebarUpdatedCardHost.rememberedHeightsKey]
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        let saved = DesignSettings.shared.uiScale
        defer {
            DesignSettings.shared.uiScale = saved
            keys.forEach(UserDefaults.standard.removeObject(forKey:))
        }
        let (sidebar, surfaces) = sidebarAtScale(1.25)
        let host = sidebar.updatedCardView
        host.configure(Self.card)
        sidebar.layoutSubtreeIfNeeded()
        try #require(surfaces.islands.last).report(height: 60)
        sidebar.layoutSubtreeIfNeeded()
        host.configure(nil)

        // The next launch runs at 100%: the card shows fresh, before its page reports.
        DesignSettings.shared.uiScale = 1
        host.configure(Self.card)
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.heldHeight == 48, "the first frame held \(host.heldHeight) points at 100%")
        #expect(host.height == 48, "the card was \(host.height) points at 100%")
    }

    /// Review F2 of #38150: a remembered card whose page has not reported yet lays out again when the
    /// scale changes, so its frame follows the rescaled hold instead of keeping its old height.
    @Test func aScaleChangeBeforeThePageReportsRelayoutsTheCard() async throws {
        let keys = [SidebarUpdatedCardHost.rememberedHeightKey, SidebarUpdatedCardHost.rememberedHeightsKey]
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        let saved = DesignSettings.shared.uiScale
        defer {
            DesignSettings.shared.uiScale = saved
            keys.forEach(UserDefaults.standard.removeObject(forKey:))
        }
        let (sidebar, surfaces) = sidebarAtScale(1.25)
        let host = sidebar.updatedCardView
        host.configure(Self.card)
        sidebar.layoutSubtreeIfNeeded()
        try #require(surfaces.islands.last).report(height: 60)
        sidebar.layoutSubtreeIfNeeded()
        host.configure(nil)

        // The card shows again at its remembered 60 points; its page has not reported.
        host.configure(Self.card)
        sidebar.layoutSubtreeIfNeeded()
        #expect(host.frame.height >= 60, "the remembered card showed at \(host.frame.height) points")

        DesignSettings.shared.uiScale = 1
        // The host hears the scale through its observation: give it a few turns.
        for _ in 0..<100 where host.frame.height > 49 {
            try await Task.sleep(for: .milliseconds(10))
            sidebar.layoutSubtreeIfNeeded()
        }
        #expect(host.height == 48, "the card was \(host.height) points at 100%")
        #expect(host.frame.height <= 49, "the card's frame kept \(host.frame.height) points at 100%")
    }
}
