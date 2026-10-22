import CmuxNextAccounts
import Testing

/// Sign Out and Re-authenticate run on this Mac, whose sign-ins Accounts
/// shows: a focused SSH or Cloud pane never receives the command.
struct AccountsLocalPaneTests {
    private struct Pane: Equatable {
        let name: String
        let local: Bool
    }

    @Test func aLocalFocusedPaneRunsTheCommand() {
        let focused = Pane(name: "focused", local: true)
        let pick = LocalPanePick(focused: focused, others: [Pane(name: "other", local: true)], isLocal: \.local)
        #expect(pick.pane == focused)
    }

    @Test func aRemoteFocusedPaneHandsTheCommandToALocalOne() {
        let local = Pane(name: "local", local: true)
        let pick = LocalPanePick(focused: Pane(name: "ssh", local: false),
                                 others: [Pane(name: "cloud", local: false), local], isLocal: \.local)
        #expect(pick.pane == local)
    }

    @Test func noLocalPaneRunsNothing() {
        let pick = LocalPanePick(focused: Pane(name: "ssh", local: false),
                                 others: [Pane(name: "cloud", local: false)], isLocal: \.local)
        #expect(pick.pane == nil)
    }
}
