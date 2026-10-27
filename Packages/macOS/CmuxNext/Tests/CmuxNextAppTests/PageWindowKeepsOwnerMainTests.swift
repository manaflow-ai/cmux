import Testing
@testable import CmuxNextApp

/// Leo, 2026-10-21: a cmux window keeps its active look while its own browser page has the
/// keyboard. Chromium's page windows never become main (`ChromiumPageWindowMain`), and AppKit does
/// not hand main to a child window's parent. With two cmux windows, a click into the page of the one
/// that is not main would leave the other main: the background window looking active, the one the
/// person types in looking inactive. The window whose page took key becomes main itself.
struct PageWindowKeepsOwnerMainTests {
    @Test func aPageOfTheWindowThatIsNotMainMakesItMain() {
        #expect(FocusEffectApplier.ownerTakesMain(ownedCanBecomeMain: false, ownerIsMain: false, ownerCanBecomeMain: true))
    }

    @Test func aPageOfTheMainWindowLeavesMainAlone() {
        #expect(!FocusEffectApplier.ownerTakesMain(ownedCanBecomeMain: false, ownerIsMain: true, ownerCanBecomeMain: true))
    }

    @Test func anOwnedWindowThatMayBeMainSettlesMainItself() {
        // AppKit makes such a window main itself when it takes key.
        #expect(!FocusEffectApplier.ownerTakesMain(ownedCanBecomeMain: true, ownerIsMain: false, ownerCanBecomeMain: true))
    }

    @Test func anOwnerThatCannotBeMainIsNotMadeMain() {
        #expect(!FocusEffectApplier.ownerTakesMain(ownedCanBecomeMain: false, ownerIsMain: false, ownerCanBecomeMain: false))
    }
}
