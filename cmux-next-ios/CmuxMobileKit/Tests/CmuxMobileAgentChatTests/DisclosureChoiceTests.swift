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

    /// A live thought shows its newest lines; it used to show its first three, which stopped
    /// changing once the agent had thought for three lines.
    @Test func aLiveThoughtShowsItsNewestLines() {
        let lines = (1...12).map { "Thought line \($0): checking the next part of the plan.\n" }
        #expect(DisclosureChoice.liveTail(of: lines.prefix(2).joined()) == "Thought line 1: checking the next part of the plan.\nThought line 2: checking the next part of the plan.")
        let tail = DisclosureChoice.liveTail(of: lines.joined())
        #expect(tail.hasPrefix("…Thought line 10:"))
        #expect(tail.hasSuffix("Thought line 12: checking the next part of the plan."))
        // One long line keeps its end, cut at a word.
        let long = DisclosureChoice.liveTail(of: String(repeating: "one long ", count: 100) + "end")
        #expect(long.hasPrefix("…") && long.hasSuffix("long end") && long.count <= 241)
    }
}
