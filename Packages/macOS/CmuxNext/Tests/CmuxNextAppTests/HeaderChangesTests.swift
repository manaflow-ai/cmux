import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The chat header's Changes button (cx-00n1, Claude Code desktop's diff toggle): it owns the diff
/// viewer beside the chat. The first click opens the diff of the chat's folder beside it, placed as
/// an agent's diff is, the second closes that diff, and the button is lit while it is open. Runs the
/// header's path against a store whose layout the actions change as the daemon would.
@MainActor
struct HeaderChangesTests {
    typealias Row = HeaderSplitOrderTests.Row

    @Test func changesOpensTheChatsDiffBesideItAndClosesIt() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("openDiffViewer", toggles: toggles)
        #expect(row.order == ["chat", "changes"])
        let opened = row.invocations["openDiffViewer"]
        #expect(opened?["path"]?.stringValue == row.cwd)
        #expect(opened?.besideCaller == true)
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit == ["openDiffViewer"])
        row.click("openDiffViewer", toggles: toggles)
        #expect(row.order == ["chat"])
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit == [])
    }

    @Test func changesJoinsThePanelsRightOfTheChatInOrder() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitRight", toggles: toggles)
        row.click("openDiffViewer", toggles: toggles)
        #expect(row.order == ["chat", "terminal", "changes"])
        // Beside the terminal, the chat's own folder still names the diff.
        #expect(row.invocations["openDiffViewer"]?["path"]?.stringValue == row.cwd)
    }
}
