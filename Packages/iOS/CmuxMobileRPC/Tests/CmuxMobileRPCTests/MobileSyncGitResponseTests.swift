import Foundation
import Testing

@testable import CmuxMobileRPC

@Suite struct MobileSyncGitResponseTests {
    @Test func statusResponseDecodesSnakeCaseWireShape() throws {
        let data = Data(#"""
        {
          "repo_root":"/repo","baseline":"worktree",
          "files":[
            {"path":"new.swift","status":"A","additions":4,"deletions":0,"binary":false,"untracked":true},
            {"path":"renamed.swift","old_path":"old.swift","status":"R","additions":1,"deletions":2,"binary":false,"untracked":false}
          ],
          "total_additions":5,"total_deletions":2,"truncated_untracked":true
        }
        """#.utf8)

        let response = try MobileSyncGitStatusResponse.decode(data)
        #expect(response.repoRoot == "/repo")
        #expect(response.baseline == "worktree")
        #expect(response.files.count == 2)
        #expect(response.files[0].oldPath == nil)
        #expect(response.files[0].untracked)
        #expect(response.files[1].oldPath == "old.swift")
        #expect(response.totalAdditions == 5)
        #expect(response.totalDeletions == 2)
        #expect(response.truncatedUntracked)
    }

    @Test func statusResponseDefaultsMissingUntrackedTruncationToFalse() throws {
        let data = Data(#"""
        {
          "repo_root":"/repo","baseline":"worktree","files":[],
          "total_additions":0,"total_deletions":0
        }
        """#.utf8)

        #expect(try !MobileSyncGitStatusResponse.decode(data).truncatedUntracked)
    }

    @Test func diffResponseDecodesBatchingMetadata() throws {
        let data = Data(#"""
        {
          "baseline":"worktree","patch":"diff --git a/a b/a\n",
          "included":["a"],"truncated":["b","c"],
          "too_large":[{"path":"huge.bin","bytes":5000000}]
        }
        """#.utf8)

        let response = try MobileSyncGitDiffResponse.decode(data)
        #expect(response.baseline == "worktree")
        #expect(response.patch == "diff --git a/a b/a\n")
        #expect(response.included == ["a"])
        #expect(response.truncated == ["b", "c"])
        #expect(response.tooLarge.count == 1)
        #expect(response.tooLarge[0].path == "huge.bin")
        #expect(response.tooLarge[0].bytes == 5_000_000)
    }
}
