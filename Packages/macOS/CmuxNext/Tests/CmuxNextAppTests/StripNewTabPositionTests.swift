import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The strip's + puts its tab where `tabs.newTabButtonPosition` says (the end by default), apart
/// from Cmd-T, whose `newTab.default` carries no mark and follows `tabs.newTabPosition`.
@MainActor struct StripNewTabPositionTests {
    @Test(arguments: [false, true]) func thePlusMarksItsInvocation(sameKind: Bool) {
        var runs: [(ActionID, ActionInvocation)] = []
        StripNewTab.request(pane: "p1", sameKind: sameKind) { runs.append(($0, $1)) }
        #expect(runs.map(\.0) == [sameKind ? StripNewTab.sameKindAction : StripNewTab.action])
        #expect(runs.first?.1[StripNewTab.button]?.boolValue == true,
                "without the mark the + would follow Cmd-T's setting instead of its own")
    }

    /// The + opens at the end unless the person picked another place for it.
    @Test func thePlusDefaultsToTheEnd() {
        #expect(NewTabPosition.buttonDefault == .end)
        #expect(NewTabSlot.target(current: nil, pane: [], explicit: nil, user: true, setting: NewTabPosition.buttonDefault) == nil)
    }
}
