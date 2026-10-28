import AppKit
@testable import CmuxNextTabs
import Testing

/// A hidden high-energy tab's hover card says "Using high energy" with a Discard button on its own
/// line, and only then takes clicks; a quiet or hibernated tab's card has neither.
@MainActor @Suite struct HighEnergyTabsCardTests {
    /// The card says it and offers Discard only for a flagged, live tab; the card then takes clicks.
    @Test func theCardSaysItWithDiscard() {
        let card = TabHoverCardView()
        var pressed = 0
        card.setHighEnergy(true) { pressed += 1 }
        card.configure(.tab(TabItem(id: TabID("busy"), title: "Busy page", subtitle: "https://example.com")))
        #expect(card.reportedLines.contains(CmuxNextTabs.Strings.usingHighEnergy))
        #expect(card.reportedLines.last == CmuxNextTabs.Strings.discard)
        #expect(card.offersDiscard)
        card.discardButton.performClick(nil)
        #expect(pressed == 1)

        card.setHighEnergy(false, discard: nil)
        card.configure(.tab(TabItem(id: TabID("quiet"), title: "Quiet page", subtitle: "https://example.com")))
        #expect(!card.reportedLines.contains(CmuxNextTabs.Strings.usingHighEnergy))
        #expect(!card.offersDiscard, "a card with no Discard takes clicks")

        var dormant = TabItem(id: TabID("asleep"), title: "Asleep", subtitle: "https://example.com")
        dormant.isDormant = true
        card.setHighEnergy(true) {}
        card.configure(.tab(dormant))
        #expect(!card.offersDiscard, "a hibernated tab offered Discard")
    }

    /// The flagged card is taller by the energy row and the button, and the button lies inside the card.
    @Test func theDiscardButtonHasItsOwnLine() {
        let item = TabItem(id: TabID("busy"), title: "Busy page", subtitle: "https://example.com")
        let card = TabHoverCardView()
        card.configure(.tab(item))
        card.setThumbnailVisible(false)
        let plain = card.fittingSize.height
        card.setHighEnergy(true) {}
        card.configure(.tab(item))
        card.setFrameSize(card.fittingSize)
        card.layoutSubtreeIfNeeded()
        #expect(card.fittingSize.height > plain + card.discardButton.fittingSize.height)
        #expect(card.bounds.contains(CGPoint(x: card.discardButton.frame.midX, y: card.discardButton.frame.midY)))
    }
}
