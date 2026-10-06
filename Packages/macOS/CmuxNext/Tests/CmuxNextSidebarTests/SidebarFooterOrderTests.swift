import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// R112/R114 (Lawrence 2026-10-04: "spaces dots should appear above
/// settings section"): from the bottom up, the Settings/account band, the
/// spaces dots directly above it, then the update card stack above the dots.
@MainActor @Suite struct SidebarFooterOrderTests {
    final class FixedCards: NSView {
        override var fittingSize: NSSize { NSSize(width: 200, height: 48) }
    }

    @Test func theDotsSitAboveTheSettingsBandAndTheCardsAboveTheDots() throws {
        let model = SidebarModel()
        model.profiles = [SidebarProfile(id: ProfileKey("a"), name: "Default"), SidebarProfile(id: ProfileKey("b"), name: "Work")]
        model.activeProfileID = ProfileKey("a")
        let view = SidebarView(model: model)
        let cards = FixedCards()
        view.footerCards = cards
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        view.layout()
        let dots = view.profileBar.convert(view.profileBar.bounds, to: view)
        let band = view.belowFade.frame
        #expect(!view.profileBar.isHidden)
        #expect(abs(band.maxY - view.bounds.maxY) < 0.5, "the Settings band is at the bottom")
        #expect(dots.maxY <= band.minY + 0.5 && dots.height > 0, "the dots sit on the band")
        let stack = cards.convert(cards.bounds, to: view)
        #expect(stack.height == 48 && stack.maxY <= dots.minY + 0.5, "the cards sit on the dots")
    }
}
