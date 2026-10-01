import CmuxNextActions
import Testing
@testable import CmuxNextApp

/// The tab strip's "+" follows Cmd-T (coordinator decision 2026-10-01): a
/// tab of the strip pane's kind, through `newTab.sameKind`.
@Suite struct StripNewTabTests {
    @Test func plusRunsTheSameKindActionOnItsPane() {
        var runs: [(ActionID, ActionInvocation)] = []
        StripNewTab.request(pane: "pane_a") { runs.append(($0, $1)) }
        #expect(runs.map(\.0) == ["newTab.sameKind"])
        #expect(runs.first?.1.target == ActionTargetRef(kind: .pane, id: "pane_a"))
    }
}
