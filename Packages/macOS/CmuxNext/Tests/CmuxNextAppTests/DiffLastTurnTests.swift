import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

/// The diff tab's Last turn (D1, D2): a chat's edited-files card opens the diff tab on that turn
/// (its checkpoint pair, diffed by the session host), at the row's file, read-only; the header's
/// Changes offers the chat's latest turn in the tab's scope menu. Before, the card opened the
/// chat folder's whole branch diff and the tab had no turn scope.
@MainActor
@Suite(.serialized)
struct DiffLastTurnTests {
    static let repository = "/Users/dev/uploader"

    /// A session host whose checkpoint diff is `reply`.
    final class TurnGit: DiffGitRunning {
        var reply: JSONValue = [:]
        var reads: [(String, String, String)] = []

        func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue { ["root": .string(repository)] }
        func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
        func write(_ request: AgentPaneGitWrite, in repository: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
        func stage(_ request: AgentPaneGitStage, in repository: String) async -> String? { nil }
        func checkpointDiff(_ repository: String, from: String, to: String) async throws(AgentPaneGitFailure) -> JSONValue {
            reads.append((repository, from, to))
            return reply
        }
    }

    /// The sidecar's answer to a patch source: the resource of the manifest's request path.
    nonisolated final class PatchSidecar: DiffSidecarRunning, @unchecked Sendable {
        func run(_ request: Data) async throws -> Data {
            let body = try JSONValue.parse(request)
            let id: JSONValue = body["id"] ?? .null
            let source: JSONValue = body["params"]?["source"] ?? .null
            let reply: JSONValue = ["id": id, "version": 1, "result": [
                "type": "sessionOpened",
                "value": ["sessionId": "11111111-2222-3333-4444-555555555555", "source": source,
                          "patch": ["id": "cmux-page://cmux.diff/__patch/t/turn.patch", "mediaType": "text/x-diff", "revision": 1],
                          "generatedPaths": []],
            ]]
            return Data(reply.compactText.utf8)
        }
    }

    @Test func aTurnsPatchHasEveryFileWithItsGitHeaders() {
        let patch = DiffTurnPatch.make(["files": [
            ["path": "src/a.ts", "status": "modified", "patch": "@@ -1 +1 @@\n-old\n+new\n"],
            ["path": "notes.md", "status": "added", "patch": "@@ -0,0 +1 @@\n+hello"],
            ["path": "gone.txt", "status": "deleted", "patch": "@@ -1 +0,0 @@\n-bye\n"],
            ["path": "lib/new.ts", "previous_path": "lib/old.ts", "status": "renamed"],
            ["path": "logo.png", "status": "modified", "binary": true],
            ["path": "big.ts", "status": "modified", "patch_truncated": true,
             "patch": "@@ -1 +1 @@\n-a\n+b\n@@ -9,3 +9,3 @@\n-c\n+"],
        ]])
        #expect(patch == """
        diff --git a/src/a.ts b/src/a.ts
        --- a/src/a.ts
        +++ b/src/a.ts
        @@ -1 +1 @@
        -old
        +new
        diff --git a/notes.md b/notes.md
        new file mode 100644
        --- /dev/null
        +++ b/notes.md
        @@ -0,0 +1 @@
        +hello
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/lib/old.ts b/lib/new.ts
        similarity index 100%
        rename from lib/old.ts
        rename to lib/new.ts
        diff --git a/logo.png b/logo.png
        Binary files a/logo.png and b/logo.png differ
        diff --git a/big.ts b/big.ts
        --- a/big.ts
        +++ b/big.ts
        @@ -1 +1 @@
        -a
        +b
        @@ -9,1 +9,1 @@
        -c
        +

        """)
        // A rename whose edit the session host left out is not a pure rename.
        #expect(DiffTurnPatch.make(["files": [["path": "b.ts", "previous_path": "a.ts", "status": "renamed", "additions": 3,
                                               "patch_truncated": true]]]).contains("similarity index 50%"))
        // A cut in a file's only hunk keeps what came of it.
        #expect(DiffTurnPatch.cutHunks("@@ -1,4 +1,4 @@\n ctx\n-old\n+ne") == "@@ -1,2 +1,2 @@\n ctx\n-old\n+ne\n")
        #expect(DiffTurnPatch.quoted("a/say \"hi\".txt") == "\"a/say \\\"hi\\\".txt\"")
        #expect(DiffTurnPatch.quoted("a/plain name.txt") == "a/plain name.txt")
    }

    @Test func aChatsTabOffersLastTurnAndACardOpensItAtTheFile() {
        let repository = DiffRepository(root: Self.repository, branch: "main", base: "origin/main")
        let turn = DiffTurn(from: "cp-1", to: "cp-2", file: "src/a.ts")
        // The header's Changes: the default scope, with Last turn in the menu.
        let header = DiffPageConfig.make(repository: repository, token: "t", turn: turn)["payload"]
        #expect(header?["sessionSource"]?["kind"]?.stringValue == "branch")
        #expect(header?["sourceOptions"]?.arrayValue?.first?["sessionSource"] == DiffTurnPatch.pageSource)
        #expect(header?["revealPath"] == nil)
        // A card: the turn's patch, at the row's file.
        let card = DiffPageConfig.make(repository: repository, source: .turn, token: "t", turn: turn)["payload"]
        #expect(card?["sessionSource"] == DiffTurnPatch.pageSource)
        #expect(card?["revealPath"]?.stringValue == "src/a.ts")
        #expect(card?["branchBaseRef"]?.stringValue == "origin/main")
        // A turn the header gave the tab later is offered too.
        let later = DiffPageConfig.offeringTurn(DiffPageConfig.make(repository: repository, token: "t"))["payload"]
        #expect(later?["sourceOptions"]?.arrayValue?.first?["sessionSource"] == DiffTurnPatch.pageSource)
        #expect(later?["sessionSource"]?["kind"]?.stringValue == "branch")
        // A tab with no chat (the palette, the CLI, a restored tab) has no Last turn.
        let plain = DiffPageConfig.make(repository: repository, source: .turn, token: "t")["payload"]
        #expect(plain?["sourceOptions"] == nil)
        #expect(plain?["sessionSource"]?["kind"]?.stringValue == "branch")
    }

    @Test func aCardTakesTheRepositorysTabInAnyScope() {
        let turn = DiffTurn(from: "cp-1", to: "cp-2", file: "a.ts")
        // A card's turn takes the tab of its repository whatever it shows, and only that repository's.
        #expect(DiffTabReuse.reuses(root: "/r", source: .staged, for: "/r", .turn))
        #expect(!DiffTabReuse.reuses(root: "/other", source: .turn, for: "/r", .turn))
        // Any other open takes the tab of the same scope, as before, and the header's also a tab a
        // card moved to its turn (no second tab of the repository).
        #expect(!DiffTabReuse.reuses(root: "/r", source: .staged, for: "/r", .default))
        #expect(DiffTabReuse.reuses(root: "/r", source: .default, for: "/r", .default))
        #expect(DiffTabReuse.reuses(root: "/r", source: .turn, for: "/r", .default))
        #expect(!DiffTabReuse.reuses(root: "/r", source: .turn, for: "/r", .staged))
        // A card reloads the tab on its turn and file, even the same turn (another file).
        #expect(DiffTabReuse.change(shownTurn: nil, .turn, turn) == .reload)
        #expect(DiffTabReuse.change(shownTurn: turn, .turn, turn) == .reload)
        // The header's newer turn becomes the tab's Last turn with no reload: the reader keeps
        // their scope, place and commit form.
        #expect(DiffTabReuse.change(shownTurn: turn, .default, DiffTurn(from: "cp-3", to: "cp-4")) == .newTurn)
        #expect(DiffTabReuse.change(shownTurn: turn, .default, DiffTurn(from: "cp-1", to: "cp-2")) == .keep)
        // The palette or the CLI names no turn and changes nothing.
        #expect(DiffTabReuse.change(shownTurn: turn, .default, nil) == .keep)
    }

    @Test func lastTurnReadsTheTurnFromTheSessionHostIntoTheTabsGrant() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-turn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: Self.repository)
        defer { grant.remove() }
        let git = TurnGit()
        git.reply = ["files": [["path": "src/a.ts", "status": "modified", "patch": "@@ -1 +1 @@\n-old\n+new\n"]]]
        let turn = DiffTurn(from: "cp-1", to: "cp-2")
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:], turn: turn) }, sidecar: PatchSidecar(),
                                        languages: nil, git: git)
        let opened = try await provider.call("cmux.diff.sessionOpen", params: ["source": DiffTurnPatch.pageSource],
                                             context: PageCallContext(page: "cmux.diff"))
        #expect(opened["type"]?.stringValue == "sessionOpened")
        #expect(git.reads.map(\.0) == [Self.repository])
        #expect(git.reads.map(\.1) == ["cp-1"])
        #expect(git.reads.map(\.2) == ["cp-2"])
        let written = try String(contentsOf: grant.turnPatchURL, encoding: .utf8)
        #expect(written.hasPrefix("diff --git a/src/a.ts b/src/a.ts\n"))
        // The grant's manifest lists the patch, so the page host serves it to this tab only.
        let resolver = DiffPatchResolver(root: grant.root, token: grant.token)
        #expect(resolver.listedFiles().map(\.lastPathComponent).contains(grant.turnPatchURL.lastPathComponent))
        await provider.close()
    }

    @Test func aTabWithNoChatTurnOpensNoTurnPatch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-turn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: Self.repository)
        defer { grant.remove() }
        let git = TurnGit()
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: PatchSidecar(),
                                        languages: nil, git: git)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.sessionOpen", params: ["source": DiffTurnPatch.pageSource],
                                        context: PageCallContext(page: "cmux.diff"))
        }
        #expect(git.reads.isEmpty)
        await provider.close()
    }

    /// The page's `pane.action` as the App decodes it: Changes with a turn runs the diff with it.
    @Test func changesWithATurnNamesItToTheDiffViewer() {
        let message = { (turn: [String: Any]) -> AgentPaneRequest in
            let params: [String: Any] = ["id": "openDiffViewer", "cwd": "/repo", "mode": "open", "turn": turn]
            return AgentPaneRequest(body: ["method": "pane.action", "params": params] as [String: Any])
        }
        guard case .diffTurn(let turn, let cwd, let toggle) = message(["from": "cp-1", "to": "cp-2", "file": "src/a.ts", "show": true])
        else {
            Issue.record("pane.action with a turn did not decode")
            return
        }
        #expect(turn == AgentPaneDiffTurn(from: "cp-1", to: "cp-2", file: "src/a.ts", show: true))
        #expect(cwd == "/repo")
        #expect(!toggle)
        // A file outside the repository is dropped; a turn with no pair is plain Changes.
        if case .diffTurn(let outside, _, _) = message(["from": "cp-1", "to": "cp-2", "file": "../etc/passwd"]) {
            #expect(outside.file == nil)
            #expect(!outside.show)
        } else {
            Issue.record("pane.action with a turn did not decode")
        }
        guard case .paneAction("openDiffViewer", _, _) = message(["from": "cp-1"]) else {
            Issue.record("pane.action without a pair is not plain Changes")
            return
        }

        // The header runs openDiffViewer beside the chat with the turn's arguments.
        let row = HeaderSplitOrderTests.Row(), toggles = AgentChatSplitToggles()
        let actions = AgentChatTabActions(tab: { [chat = row.chat] in chat }, registry: { [registry = row.registry] in registry })
        toggles.open("openDiffViewer", cwd: row.cwd, extra: DiffTurnArgument.arguments(turn), chat: row.chat, store: row.store,
                     actions: actions)
        let invocation = row.invocations["openDiffViewer"]
        #expect(invocation?["path"]?.stringValue == row.cwd)
        #expect(invocation?.besideCaller == true)
        #expect(invocation.flatMap(ViewerHandlers.diffTurn) == DiffTurn(from: "cp-1", to: "cp-2", file: "src/a.ts"))
        #expect(invocation?[DiffTurnArgument.show]?.boolValue == true)
    }
}
