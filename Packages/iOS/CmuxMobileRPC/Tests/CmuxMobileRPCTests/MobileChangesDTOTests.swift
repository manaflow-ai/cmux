import Foundation
import Testing

@testable import CmuxMobileRPC

/// Pins the native changes DTOs to the exact Slice 1 snake-case wire shapes.
@Suite struct MobileChangesDTOTests {
    @Test func summaryDecodesFilesAndPreservesUnknownStatus() throws {
        let json = #"""
        {
          "base_info": {
            "kind": "working_tree",
            "resolved_ref": "HEAD",
            "describe": "Working tree"
          },
          "totals": { "files": 2, "additions": 7, "deletions": 3 },
          "files": [
            {
              "path": "Sources/New.swift",
              "status": "added",
              "additions": 7,
              "deletions": 0,
              "is_binary": false,
              "is_large": false,
              "patch_digest": "digest-new"
            },
            {
              "path": "Assets/Future.bin",
              "old_path": "Assets/Old.bin",
              "status": "future_status",
              "additions": 0,
              "deletions": 3,
              "is_binary": true,
              "is_large": true,
              "patch_digest": "digest-future"
            }
          ],
          "truncated_file_count": 4
        }
        """#

        let response = try MobileChangesSummaryResponse.decode(Data(json.utf8))

        #expect(response.baseInfo.kind == .workingTree)
        #expect(response.baseInfo.resolvedRef == "HEAD")
        #expect(response.totals == MobileChangesTotals(files: 2, additions: 7, deletions: 3))
        #expect(response.files[0].oldPath == nil)
        #expect(response.files[0].status == .added)
        #expect(response.files[1].oldPath == "Assets/Old.bin")
        #expect(response.files[1].status == .unknown("future_status"))
        #expect(response.truncatedFileCount == 4)
    }

    @Test func fileResponseDecodesHunksWithAbsentNextCursor() throws {
        let json = #"""
        {
          "hunks": [
            {
              "old_start": 10,
              "old_lines": 2,
              "new_start": 10,
              "new_lines": 2,
              "section_heading": "func render()",
              "rows": [
                { "kind": "context", "old_no": 10, "new_no": 10, "text": "let a = 1" },
                { "kind": "del", "old_no": 11, "new_no": null, "text": "old" },
                { "kind": "add", "old_no": null, "new_no": 11, "text": "new" },
                { "kind": "noNewline", "old_no": null, "new_no": null, "text": "\\ No newline at end of file" }
              ]
            }
          ],
          "is_binary": false,
          "too_large": false
        }
        """#

        let response = try MobileChangesFileResponse.decode(Data(json.utf8))

        #expect(response.nextCursor == nil)
        #expect(response.hunks.first?.sectionHeading == "func render()")
        #expect(response.hunks.first?.rows.map(\.kind) == [.context, .del, .add, .noNewline])
        #expect(response.hunks.first?.rows[1].newNo == nil)
        #expect(response.hunks.first?.rows[2].oldNo == nil)
    }

    @Test func contextResponseDecodesRows() throws {
        let response = try MobileChangesContextResponse.decode(
            Data(#"{"rows":["alpha","beta",""]}"#.utf8)
        )

        #expect(response.rows == ["alpha", "beta", ""])
    }

    @Test func requestsEncodeExactSnakeCaseParametersAndOmitNilCursorFields() throws {
        let baseSpec = MobileChangesBaseSpec(kind: .branchBase, value: "origin/main")
        let summary = try encodedObject(MobileChangesSummaryRequest(
            workspaceID: "workspace-1",
            baseSpec: baseSpec,
            ignoreWhitespace: true
        ))
        #expect(summary["workspace_id"] as? String == "workspace-1")
        #expect(summary["ignore_whitespace"] as? Bool == true)
        let encodedBase = try #require(summary["base_spec"] as? [String: Any])
        #expect(encodedBase["kind"] as? String == "branch_base")
        #expect(encodedBase["value"] as? String == "origin/main")

        let file = try encodedObject(MobileChangesFileRequest(
            workspaceID: "workspace-1",
            path: "Sources/App.swift",
            oldPath: nil,
            cursor: nil,
            ignoreWhitespace: false,
            baseSpec: .init(kind: .workingTree)
        ))
        #expect(file["old_path"] == nil)
        #expect(file["cursor"] == nil)
        #expect(file["ignore_whitespace"] as? Bool == false)

        let context = try encodedObject(MobileChangesContextRequest(
            workspaceID: "workspace-1",
            path: "Sources/App.swift",
            startLine: 12,
            endLine: 18,
            baseSpec: .init(kind: .lastTurn)
        ))
        #expect(context["start_line"] as? Int == 12)
        #expect(context["end_line"] as? Int == 18)
    }

    private func encodedObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
