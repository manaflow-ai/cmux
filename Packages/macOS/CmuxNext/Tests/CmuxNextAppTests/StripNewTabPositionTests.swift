import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The strip's + sits after the last tab, so its tab opens at the end, whatever
/// `tabs.newTabPosition` says; Cmd-T (`newTab.default` with no argument) follows the setting.
@MainActor struct StripNewTabPositionTests {
    @Test(arguments: [false, true]) func thePlusAsksForTheEnd(sameKind: Bool) {
        var runs: [(ActionID, ActionInvocation)] = []
        StripNewTab.request(pane: "p1", sameKind: sameKind) { runs.append(($0, $1)) }
        #expect(runs.map(\.0) == [sameKind ? StripNewTab.sameKindAction : StripNewTab.action])
        let position = runs.first?.1[StripNewTab.position]?.stringValue.flatMap(NewTabPosition.init(rawValue:))
        #expect(position == .end, "the + must open its tab at the end, not after the selected tab")
    }

    /// The end is no slot: the daemon appends, whatever the person's setting.
    @Test(arguments: NewTabPosition.allCases) func anExplicitEndIgnoresTheSetting(setting: NewTabPosition) {
        #expect(NewTabSlot.target(current: nil, pane: [], explicit: .end, user: true, setting: setting) == nil)
    }
}
