import Testing
@testable import CmuxMobileAgentChat

/// "Disclosure groups not being properly closable": a row that opens on its
/// own (a live thought) closes on the first tap and keeps the person's choice.
@Suite struct DisclosureChoiceTests {
    @Test func aLiveRowClosesOnTheFirstTap() {
        var choice = DisclosureChoice()
        #expect(choice.isOpen(automatic: true))
        choice.toggle(automatic: true)
        #expect(!choice.isOpen(automatic: true))
        // Still closed when the thought ends.
        #expect(!choice.isOpen(automatic: false))
    }

    @Test func aClosedRowOpensAndClosesEachTap() {
        var choice = DisclosureChoice()
        #expect(!choice.isOpen(automatic: false))
        choice.toggle(automatic: false)
        #expect(choice.isOpen(automatic: false))
        #expect(choice.chosen == true)
        choice.toggle(automatic: false)
        #expect(!choice.isOpen(automatic: false))
        // The person's choice outlasts the automatic state.
        #expect(!choice.isOpen(automatic: true))
    }
}
