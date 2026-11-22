import Testing
@testable import CmuxNextApp

/// The applier's rule for a window other than the cmux window becoming key
/// (input-spec.md B7, B11, B13).
@Suite struct ChildWindowKeyRuleTests {
    /// nxdog13: the new page's CefNSWindow became key 53 ms after attach,
    /// with no click, before the fork made it a child window.
    private let nxdog13 = ChildWindowKeyRule.Facts(parent: .none, isChromiumPage: true, clicked: false, overPane: false,
                                                   thisWindowIsActive: true)

    @Test func aParentlessPageWindowOfTheActiveWindowIsAnUnchosenKey() {
        #expect(ChildWindowKeyRule.decide(nxdog13) == .unchosenPage)
        #expect(ChildWindowKeyRule.shouldReclaim(nxdog13))
    }

    /// Only the active cmux window answers for a parentless page window, so
    /// two windows never both take the keys back.
    @Test func anInactiveWindowIgnoresAParentlessPageWindow() {
        var facts = nxdog13
        facts.thisWindowIsActive = false
        #expect(ChildWindowKeyRule.decide(facts) == .ignore)
        #expect(!ChildWindowKeyRule.shouldReclaim(facts))
    }

    /// Other parentless windows (Chromium's own windows, other apps' panels)
    /// are not ours to take the keys from.
    @Test func otherParentlessWindowsAreIgnored() {
        var facts = nxdog13
        facts.isChromiumPage = false
        #expect(ChildWindowKeyRule.decide(facts) == .ignore)
        #expect(!ChildWindowKeyRule.shouldReclaim(facts))
        facts = nxdog13
        facts.isPanel = true
        #expect(ChildWindowKeyRule.decide(facts) == .ignore)
    }

    @Test func childWindowsKeepTheirRules() {
        let child = ChildWindowKeyRule.Facts(parent: .thisWindow, isChromiumPage: true, clicked: true, overPane: true)
        #expect(ChildWindowKeyRule.decide(child) == .chosenPage)
        var unplaced = child
        unplaced.overPane = false
        #expect(ChildWindowKeyRule.decide(unplaced) == .unchosenPage)
        var popup = ChildWindowKeyRule.Facts(parent: .thisWindow, isChromiumPage: false, clicked: false, overPane: true)
        #expect(ChildWindowKeyRule.decide(popup) == .reapply)
        popup.overPane = false
        #expect(ChildWindowKeyRule.decide(popup) == .ignore)
        #expect(ChildWindowKeyRule.decide(.init(parent: .other, isChromiumPage: true)) == .ignore)
        #expect(ChildWindowKeyRule.shouldReclaim(child))
    }
}
