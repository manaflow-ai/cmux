import Foundation
import Testing

@testable import CmuxMobileRPC

@Suite struct MobileWorkspaceChangesDTODecodeTests {
    @Test func summariesDecodeRealisticBatchAndSkipMalformedEntry() throws {
        let data = Data("""
        {
          "summaries": [
            {
              "workspace_id": "2A7DF0A7-94CF-44E2-A203-34D7869B11A5",
              "is_repo": true,
              "repo_root": "/Users/test/cmux",
              "branch": "feat-ios-diffv",
              "base_ref": "origin/main",
              "files_changed": 12,
              "additions": 340,
              "deletions": 85
            },
            "not-an-object",
            {"workspace_id": "legacy", "is_repo": false}
          ]
        }
        """.utf8)

        let response = try MobileWorkspaceChangesSummariesResponse.decode(data)
        #expect(response.summaries.count == 2)
        let changed = try #require(response.summaries.first)
        #expect(changed.workspaceID == "2A7DF0A7-94CF-44E2-A203-34D7869B11A5")
        #expect(changed.isRepository)
        #expect(changed.repoRoot == "/Users/test/cmux")
        #expect(changed.branch == "feat-ios-diffv")
        #expect(changed.baseRef == "origin/main")
        #expect(changed.filesChanged == 12)
        #expect(changed.additions == 340)
        #expect(changed.deletions == 85)
        let missingOptionals = try #require(response.summaries.last)
        #expect(missingOptionals.repoRoot == nil)
        #expect(missingOptionals.branch == nil)
        #expect(missingOptionals.baseRef == nil)
        #expect(missingOptionals.filesChanged == 0)
    }

    @Test func changedFilesDecodeStatusesDefaultsAndSkipMalformedEntry() throws {
        let data = Data("""
        {
          "workspace_id": "2A7DF0A7-94CF-44E2-A203-34D7869B11A5",
          "repo_root": "/Users/test/cmux",
          "branch": "feat-ios-diffv",
          "base_ref": "origin/main",
          "files": [
            {
              "path": "Sources/New.swift",
              "status": "added",
              "additions": 12,
              "deletions": 0,
              "is_binary": false,
              "is_approximate": true
            },
            {
              "path": "Sources/Renamed.swift",
              "old_path": "Sources/Old.swift",
              "status": "renamed",
              "additions": 1,
              "deletions": 1,
              "is_binary": false
            },
            {"path": "future.dat", "status": "copied"},
            {"status": "modified", "additions": 3},
            {"path": "", "status": "modified"},
            42
          ],
          "files_changed": 3,
          "additions": 13,
          "deletions": 1,
          "truncated": true
        }
        """.utf8)

        let response = try MobileWorkspaceChangedFilesResponse.decode(data)
        #expect(response.workspaceID == "2A7DF0A7-94CF-44E2-A203-34D7869B11A5")
        #expect(response.repoRoot == "/Users/test/cmux")
        // The identity-less and empty-path objects are omitted like the
        // non-object entry; identity must never default to "".
        #expect(response.files.count == 3)
        #expect(response.files.allSatisfy { !$0.path.isEmpty })
        #expect(response.files[0].status == .added)
        #expect(response.files[0].isApproximate == true)
        #expect(response.files[1].status == .renamed)
        #expect(response.files[1].oldPath == "Sources/Old.swift")
        #expect(response.files[1].isApproximate == nil)
        #expect(response.files[2].status == .unknown)
        #expect(response.files[2].additions == 0)
        #expect(response.files[2].deletions == 0)
        #expect(!response.files[2].isBinary)
        #expect(response.filesChanged == 3)
        #expect(response.truncated)
    }

    @Test func changedFilesTreatMissingFieldsAsDefaults() throws {
        let response = try MobileWorkspaceChangedFilesResponse.decode(Data("{}".utf8))
        #expect(response.workspaceID.isEmpty)
        #expect(response.repoRoot.isEmpty)
        #expect(response.branch == nil)
        #expect(response.baseRef == nil)
        #expect(response.files.isEmpty)
        #expect(response.filesChanged == 0)
        #expect(!response.truncated)
    }

    @Test func fileDiffDecodesRealisticPayloadAndUnknownStatus() throws {
        let data = Data("""
        {
          "path": "Sources/Foo.swift",
          "old_path": null,
          "status": "future_status",
          "is_binary": false,
          "additions": 2,
          "deletions": 1,
          "unified_diff": "@@ -1 +1,2 @@\\n-old\\n+new\\n+line\\n",
          "truncated": true,
          "diff_total_lines": 12004,
          "content_fingerprint": "stat:42:100:2:300:200"
        }
        """.utf8)

        let response = try MobileWorkspaceFileDiffResponse.decode(data)
        #expect(response.path == "Sources/Foo.swift")
        #expect(response.oldPath == nil)
        #expect(response.status == .unknown)
        #expect(response.additions == 2)
        #expect(response.deletions == 1)
        #expect(response.unifiedDiff.hasPrefix("@@ -1 +1,2 @@"))
        #expect(response.truncated)
        #expect(response.diffTotalLines == 12_004)
        #expect(response.contentFingerprint == "stat:42:100:2:300:200")
    }

    @Test func fileDiffTreatsMissingFieldsAsDefaults() throws {
        let response = try MobileWorkspaceFileDiffResponse.decode(Data("{}".utf8))
        #expect(response.path.isEmpty)
        #expect(response.oldPath == nil)
        #expect(response.status == .unknown)
        #expect(!response.isBinary)
        #expect(response.unifiedDiff.isEmpty)
        #expect(!response.truncated)
        #expect(response.diffTotalLines == nil)
        #expect(response.contentFingerprint == nil)
    }
}
