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
}
