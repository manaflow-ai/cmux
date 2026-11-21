import CmuxNextAgentPane
@testable import CmuxNextApp
import Testing

/// The title menu's Move to machine is bound to the chat whose menu was opened (cmux#25661): the
/// host moves the tab only while it still shows that chat.
struct AgentTitleMoveBindingTests {
    @Test func movesOnlyTheMenusChat() {
        #expect(AgentPaneMoveTarget.tabStillShows("chat-a", requested: "chat-a"))
        #expect(!AgentPaneMoveTarget.tabStillShows("chat-b", requested: "chat-a"))
        #expect(!AgentPaneMoveTarget.tabStillShows(nil, requested: "chat-a"))
        #expect(!AgentPaneMoveTarget.tabStillShows("chat-a", requested: ""))
    }

    /// No targets from a signed-out app or a list not loaded for the account signed in now (an
    /// account change, a failed refresh): a stale machine is never offered or moved to.
    @Test func offersTargetsOnlyFromTheCurrentAccountsLoadedList() {
        #expect(AgentPaneMoveTarget.offered(signedIn: true, loadedCurrent: true))
        #expect(!AgentPaneMoveTarget.offered(signedIn: true, loadedCurrent: false))
        #expect(!AgentPaneMoveTarget.offered(signedIn: false, loadedCurrent: true))
    }
}
