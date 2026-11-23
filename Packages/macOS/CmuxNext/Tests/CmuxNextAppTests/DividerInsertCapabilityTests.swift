import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Testing

/// Insert New is refused on a daemon whose split path for the kind cannot carry the insertion's `around` and
/// sizing: each kind's fallback (a plain split, or a tab moved to a split) splits only the target pane, which would
/// put the pane inside the first side instead of between the divider's sides (review of #37733).
struct DividerInsertCapabilityTests {
    @Test func eachKindNeedsTheSplitPathThatCarriesItsInsertion() {
        #expect(DividerInsertKind.terminal.splitCapabilities == [.terminalPlacementEnv])
        #expect(DividerInsertKind.browser.splitCapabilities == [.frontendBrowserTabSplit, .splitClientKeys])
        #expect(DividerInsertKind.agentChat.splitCapabilities == [.conversationTabSplit])
        #expect(DividerInsertKind.newTabPage.splitCapabilities == [.conversationTabSplit])
    }
}
