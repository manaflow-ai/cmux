import CmuxNextActions
import Testing
@testable import CmuxNextApp

/// The tab strip's location field focuses the address bar through the
/// registry's own Focus Address Bar (the Cmd-L, menu and palette action) on
/// the strip's pane: no second focus path.
@Suite struct StripLocationTests {
    @Test func aClickRunsFocusAddressBarOnItsPane() {
        var runs: [(ActionID, ActionInvocation)] = []
        StripLocation.request(pane: "pane_a") { runs.append(($0, $1)) }
        #expect(runs.map(\.0) == ["focusBrowserAddressBar"])
        #expect(runs.first?.1.target == ActionTargetRef(kind: .pane, id: "pane_a"))
    }
}
