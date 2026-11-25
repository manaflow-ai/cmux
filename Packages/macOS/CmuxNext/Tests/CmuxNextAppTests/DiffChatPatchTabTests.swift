import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

/// Changes for a turn no git source holds (a chat folder in no repository, a file the turn wrote
/// outside it) opens a diff tab beside the chat that shows the chat's own patch (Leo, 2026-11-03:
/// "the diff thing/changes viewer still doesn't open up on the right pane? why? just put it in a
/// tab???"). Before, the page drew its own changes view over the chat and nothing reached the App.
@MainActor
@Suite(.serialized)
struct DiffChatPatchTabTests {
    static let patch = "diff --git a//tmp/l-setup.txt b//tmp/l-setup.txt\n--- /dev/null\n+++ b//tmp/l-setup.txt\n@@ -0,0 +1,1 @@\n+hello\n"

    /// A sidecar that must never be asked: a chat patch tab answers every op itself.
    nonisolated final class NoSidecar: DiffSidecarRunning, @unchecked Sendable {
        // concurrency-allow: the test's provider calls it one request at a time, then the test reads it
        nonisolated(unsafe) var asked = 0
        func run(_ request: Data) async throws -> Data {
            asked += 1
            throw DiffSidecarError.failed(status: 1)
        }
    }

    @Test func changesWithAPatchDecodesAndRunsTheDiffViewerWithIt() {
        let message = { (patch: Any) -> AgentPaneRequest in
            let params: [String: Any] = ["id": "openDiffViewer", "cwd": "/Users/me/notes", "mode": "toggle", "patch": patch]
            return AgentPaneRequest(body: ["method": "pane.action", "params": params] as [String: Any])
        }
        guard case .diffPatch(let patch, let cwd, let toggle) = message(["text": Self.patch, "file": "/tmp/l-setup.txt"]) else {
            Issue.record("pane.action with a patch did not decode")
            return
        }
        #expect(patch == AgentPaneDiffPatch(text: Self.patch, file: "/tmp/l-setup.txt"))
        #expect(cwd == "/Users/me/notes")
        #expect(toggle)
        // Text that is no patch is plain Changes.
        guard case .paneAction("openDiffViewer", _, _) = message(["text": "rm -rf /"]) else {
            Issue.record("pane.action with no patch text is not plain Changes")
            return
        }

        // The header runs openDiffViewer beside the chat with the patch's arguments.
        let row = HeaderSplitOrderTests.Row(), toggles = AgentChatSplitToggles()
        let actions = AgentChatTabActions(tab: { [chat = row.chat] in chat }, registry: { [registry = row.registry] in registry })
        toggles.open("openDiffViewer", cwd: row.cwd, extra: patch.actionArguments, chat: row.chat, store: row.store,
                     actions: actions)
        let invocation = row.invocations["openDiffViewer"]
        #expect(invocation?.besideCaller == true)
        #expect(invocation?[AgentPaneDiffPatch.textArgument]?.stringValue == Self.patch)
        #expect(invocation?[AgentPaneDiffPatch.fileArgument]?.stringValue == "/tmp/l-setup.txt")
    }

    @Test func theTabsConfigOffersOnlyTheTurnAtItsFile() {
        let payload = DiffPageConfig.chatPatch(title: "notes", token: "t", file: "/tmp/l-setup.txt")["payload"]
        #expect(payload?["sessionSource"] == DiffTurnPatch.pageSource)
        #expect(payload?["repoRoot"] == nil)
        #expect(payload?["sourceOptions"]?.arrayValue?.count == 1)
        #expect(payload?["revealPath"]?.stringValue == "/tmp/l-setup.txt")
        #expect(payload?["title"]?.stringValue == "notes")
    }

    @Test func theTabServesTheChatsPatchWithNoSidecarGitOrFileOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-chat-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DiffPageRuntime(root: root, sidecar: .some(nil))
        let sidecar = NoSidecar()
        let provider = DiffPageProvider(ready: runtime.prepare(chatPatch: DiffChatPatch(text: Self.patch, folder: "/Users/me/notes")),
                                        sidecar: sidecar, languages: nil, chatPatch: true)
        let context = PageCallContext(page: "cmux.diff")
        let config = try await provider.call("cmux.diff.config", params: [:], context: context)
        #expect(config["payload"]?["sessionSource"] == DiffTurnPatch.pageSource)
        #expect(config["payload"]?["title"]?.stringValue == "notes")
        #expect(config["ops"]?.arrayValue?.contains(.string(DiffPageProvider.openFileOp)) != true)
        let handshake = try await provider.call("cmux.diff.protocolHandshake", params: [:], context: context)
        #expect(handshake["type"]?.stringValue == "handshake")
        let opened = try await provider.call("cmux.diff.sessionOpen", params: ["source": DiffTurnPatch.pageSource], context: context)
        #expect(opened["type"]?.stringValue == "sessionOpened")
        let ready = try await provider.ready!.value
        #expect(try String(contentsOf: ready.grant.turnPatchURL, encoding: .utf8) == Self.patch)
        // The grant names the session root, never a folder of the person's.
        #expect(ready.grant.repository == root.path)
        // Any other source, git op or file open is refused.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.sessionOpen", params: ["source": ["kind": "unstaged", "repoRoot": "/"]], context: context)
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.git.status", params: [:], context: context)
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call(DiffPageProvider.openFileOp, params: ["path": "a.txt"], context: context)
        }
        await provider.close()
        #expect(sidecar.asked == 0)
    }
}
