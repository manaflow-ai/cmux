import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

/// A chat turn's own diff in the diff viewer (Leo, 2026-10-22: "why's the diff viewer not opening up
/// in the right split tab? what about the existing diff viewer elsewhere that was previously made?"):
/// a turn in a folder outside a repository has no git diff, so its tab shows the turn's patch. The
/// grant lists the patch for the tab's token alone and allows no repository; the page opens it as its
/// Last turn source; closing the tab removes it.
struct DiffTurnPatchTests {
    static let patch = DiffPatch(title: "scratchpad", text: """
        diff --git a/batch.sh b/batch.sh
        --- /dev/null
        +++ b/batch.sh
        @@ -0,0 +1,2 @@
        +#!/bin/bash
        +wait

        """)

    @Test func aPatchTabsGrantServesItsPatchAndNoRepository() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: nil, patch: Data(Self.patch.text.utf8))
        #expect(grant.repository == nil)
        let session = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appending(path: ".branch-session-\(grant.group).json"))) as? [String: Any])
        #expect((session["allowedRepoRoots"] as? [String])?.isEmpty == true)

        let url = try #require(URL(string: "cmux-page://cmux.diff/__patch/\(grant.token)/turn.patch"))
        let request = PageResourceRequest(prefix: DiffPatchResolver.prefix, path: [grant.token, "turn.patch"], url: url)
        let file = try #require(DiffPatchResolver(root: root, token: grant.token).file(for: request))
        #expect(try String(contentsOf: file, encoding: .utf8) == Self.patch.text)
        // Another token never reads it.
        let other = try DiffSessionGrant.create(root: root, repository: nil)
        let stranger = PageResourceRequest(prefix: DiffPatchResolver.prefix, path: [other.token, "turn.patch"], url: url)
        #expect(DiffPatchResolver(root: root, token: other.token).file(for: stranger) == nil)
        #expect(DiffPatchResolver(root: root, token: other.token).file(for: request) == nil)

        grant.remove()
        other.remove()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true)
    }

    @Test func aPatchTabsPageOpensThePatchUnderTheChatFoldersName() {
        let config = DiffPageConfig.make(patch: Self.patch, token: "0123456789abcdef0123")
        let payload = config["payload"]
        #expect(payload?["title"]?.stringValue == "scratchpad")
        #expect(payload?["capabilityToken"]?.stringValue == "0123456789abcdef0123")
        #expect(payload?["sessionSource"] == ["kind": "patch", "path": "/turn.patch"])
        // No repository: no git source to switch to, and no repository in the title bar.
        #expect(payload?["repoRoot"] == nil)
        #expect(DiffPageConfig.make(patch: DiffPatch(title: "", text: "x"), token: "t")["payload"]?["title"]?.stringValue
            == DiffPageStrings.tabTitle)
    }
}
