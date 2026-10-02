import CmuxNextActions
import Testing
@testable import CmuxNextApp

/// The tab strip's location field focuses the address bar through the
/// registry's own Focus Address Bar (the Cmd-L, menu and palette action) on
/// the strip's pane: no second focus path. That action needs a focused page
/// in the focused pane, so an unfocused pane is focused first.
@Suite struct StripLocationTests {
    private func run(isFocused: Bool) -> [String] {
        var log: [String] = []
        StripLocation.request(pane: "pane_a", isFocused: isFocused, focus: { log.append("focus") }, perform: { id, invocation in
            #expect(invocation.target == ActionTargetRef(kind: .pane, id: "pane_a"))
            log.append(id.rawValue)
        })
        return log
    }

    @Test func anUnfocusedPaneIsFocusedBeforeTheActionRuns() {
        #expect(run(isFocused: false) == ["focus", "focusBrowserAddressBar"])
    }

    @Test func aFocusedPaneRunsTheActionWithoutRefocusing() {
        #expect(run(isFocused: true) == ["focusBrowserAddressBar"])
    }
}
