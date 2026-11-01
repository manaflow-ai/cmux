import Foundation
import Testing

// The tab grid is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
@testable import CmuxTabsKit

/// A card the grid has not built (outside the residency band) is a stand-in element. VoiceOver
/// gets the same actions from it as from a built card: Open, and Close for a regular card.
@MainActor
@Suite struct CardStandInAccessibilityTests {
    @Test func anUnbuiltCardOffersOpenAndClose() {
        var opened = 0
        var closed = 0
        let standIn = CardStandIn(label: "Docs, tab", rect: .zero, open: { opened += 1 }, close: { closed += 1 })
        #expect(standIn.actions.map(\.name) == ["Open", "Close"])
        standIn.actions.first { $0.name == "Close" }?.run()
        standIn.actions.first { $0.name == "Open" }?.run()
        #expect(closed == 1)
        #expect(opened == 1)
    }

    /// A pinned card's built capsule has no Close action, so its stand-in has none either.
    @Test func anUnbuiltPinnedCardOffersOpenOnly() {
        let standIn = CardStandIn(label: "Docs, Pinned", rect: .zero, open: {}, close: nil)
        #expect(standIn.actions.map(\.name) == ["Open"])
    }
}
#endif
