import CmuxNextActions
import CmuxNextAgentPane
import Foundation
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

    @Test func changesUsesTheChatAsItsPlacementSource() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitRight", toggles: toggles)
        row.click("openDiffViewer", toggles: toggles)
        #expect(row.invocations["openDiffViewer"]?.target?.id == row.chat)
        #expect(row.invocations["openDiffViewer"]?.newColumnBeside == true)
        // The shared placement owner measures the whole right column from the chat.
        #expect(row.invocations["openDiffViewer"]?["path"]?.stringValue == row.cwd)
    }

    /// A chat folder written from the home folder (`~/code/cmux`, as acpmux may record it) names
    /// that folder in the diff: the page's `pane.action` message as the App decodes it, clicked (cx-awk8).
    @Test func aFolderWrittenFromHomeNamesItInTheDiff() {
        let message = { (cwd: String) in
            AgentPaneRequest(body: ["method": "pane.action", "params": ["id": "openDiffViewer", "cwd": cwd, "mode": "toggle"]])
        }
        let home = NSHomeDirectory()
        for (written, folder) in [("~/code/cmux", home + "/code/cmux"), ("~", home), ("/repo", "/repo")] {
            guard case .paneAction(let id, let cwd, let toggle) = message(written) else {
                Issue.record("pane.action \(written) did not decode")
                continue
            }
            let row = Row(), toggles = AgentChatSplitToggles()
            let actions = AgentChatTabActions(tab: { [chat = row.chat] in chat }, registry: { [registry = row.registry] in registry })
            #expect(toggle)
            toggles.toggle(id, cwd: cwd, chat: row.chat, store: row.store, actions: actions)
            #expect(row.invocations["openDiffViewer"]?["path"]?.stringValue == folder)
        }
        // Another user's home and a relative folder name no folder.
        for written in ["~root/code", "code/cmux"] {
            guard case .paneAction(_, let cwd, _) = message(written) else {
                Issue.record("pane.action \(written) did not decode")
                continue
            }
            #expect(cwd == nil)
        }
    }
}
