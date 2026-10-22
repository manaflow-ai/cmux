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

    @Test func changesJoinsThePanelsRightOfTheChatInOrder() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitRight", toggles: toggles)
        row.click("openDiffViewer", toggles: toggles)
        #expect(row.order == ["chat", "terminal", "changes"])
        // Beside the terminal, the chat's own folder still names the diff.
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

    /// View changes on a turn the chat folder's diff does not hold (a scratch folder outside any
    /// repository, Leo 2026-10-22: "why's the diff viewer not opening up in the right split tab?"):
    /// the page sends the turn's patch, and the diff viewer opens it beside the chat as Changes opens
    /// the folder's diff, lit, with no folder named.
    @Test func aTurnsOwnPatchOpensInTheDiffViewerBesideTheChat() {
        let text = "diff --git a/batch.sh b/batch.sh\n--- /dev/null\n+++ b/batch.sh\n@@ -0,0 +1 @@\n+wait\n"
        let message = AgentPaneRequest(body: ["method": "pane.action", "params": [
            "id": "openDiffViewer", "patch": text, "title": "scratchpad", "mode": "open",
        ]])
        guard case .diffPatch(let title, let patch) = message else {
            Issue.record("pane.action with a patch did not decode")
            return
        }
        let row = Row(), toggles = AgentChatSplitToggles()
        let actions = AgentChatTabActions(tab: { [chat = row.chat] in chat }, registry: { [registry = row.registry] in registry })
        toggles.openPatch(patch, title: title, chat: row.chat, store: row.store, actions: actions)
        #expect(row.order == ["chat", "changes"])
        let opened = row.invocations["openDiffViewer"]
        #expect(opened?["patch"]?.stringValue == text)
        #expect(opened?["title"]?.stringValue == "scratchpad")
        #expect(opened?["path"] == nil)
        #expect(opened?.besideCaller == true)
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit == ["openDiffViewer"])
        // Changes then closes it, as it closes the folder's diff.
        row.click("openDiffViewer", toggles: toggles)
        #expect(row.order == ["chat"])
    }

    /// A patch the page must not send: empty, or past the limit (the page opens those in place).
    @Test func anEmptyOrOversizedPatchIsRefused() {
        let message = { (patch: String) in
            AgentPaneRequest(body: ["method": "pane.action", "params": ["id": "openDiffViewer", "patch": patch]])
        }
        for patch in ["", String(repeating: "+", count: AgentPaneRequest.maximumDiffPatchText + 1)] {
            guard case .unsupported = message(patch) else {
                Issue.record("a patch of \(patch.count) characters decoded")
                continue
            }
        }
        guard case .diffPatch(let title, _) = message("+x\n") else {
            Issue.record("an untitled patch did not decode")
            return
        }
        #expect(title.isEmpty)
    }
}
