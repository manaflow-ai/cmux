import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileDiffDTODecodeTests {
    @Test func decodesCapturedSummaryShape() throws {
        let data = Data(#"""
        {
          "baseInfo": {"kind":"branchBase","resolvedRef":"abc123","describe":"main"},
          "totals": {"files":2,"additions":13,"deletions":5},
          "files": [
            {
              "path":"Sources/New Name.swift",
              "oldPath":"Sources/Old Name.swift",
              "status":"renamed",
              "additions":3,
              "deletions":2,
              "isBinary":false,
              "isLarge":false,
              "patchDigest":"0123456789abcdef"
            },
            {
              "path":"Assets/icon.bin",
              "oldPath":null,
              "status":"untracked",
              "additions":10,
              "deletions":3,
              "isBinary":true,
              "isLarge":true,
              "patchDigest":"fedcba9876543210"
            }
          ],
          "truncatedFileCount":4
        }
        """#.utf8)

        let response = try JSONDecoder().decode(MobileDiffSummaryResponse.self, from: data)

        #expect(response.baseInfo == MobileDiffBaseInfo(
            kind: .branchBase,
            resolvedRef: "abc123",
            describe: "main"
        ))
        #expect(response.totals == MobileDiffTotals(files: 2, additions: 13, deletions: 5))
        #expect(response.files.count == 2)
        #expect(response.files[0].path == "Sources/New Name.swift")
        #expect(response.files[0].oldPath == "Sources/Old Name.swift")
        #expect(response.files[0].status == .renamed)
        #expect(response.files[0].patchDigest == "0123456789abcdef")
        #expect(response.files[1].oldPath == nil)
        #expect(response.files[1].status == .untracked)
        #expect(response.files[1].isBinary && response.files[1].isLarge)
        #expect(response.truncatedFileCount == 4)
    }

    @Test func decodesCapturedFileShape() throws {
        let data = Data(#"""
        {
          "hunks": [
            {
              "oldStart":7,
              "oldLines":3,
              "newStart":7,
              "newLines":4,
              "sectionHeading":"func render()",
              "rows":[
                {"kind":"context","oldNo":7,"newNo":7,"text":"let a = 1"},
                {"kind":"del","oldNo":8,"newNo":null,"text":"return old"},
                {"kind":"add","oldNo":null,"newNo":8,"text":"return new"},
                {"kind":"noNewline","oldNo":null,"newNo":null,"text":"No newline at end of file"}
              ]
            }
          ],
          "isBinary":false,
          "tooLarge":false,
          "nextCursor":120
        }
        """#.utf8)

        let response = try JSONDecoder().decode(MobileDiffFileResponse.self, from: data)

        #expect(response.hunks.count == 1)
        let hunk = response.hunks[0]
        #expect(hunk.oldStart == 7 && hunk.oldLines == 3)
        #expect(hunk.newStart == 7 && hunk.newLines == 4)
        #expect(hunk.sectionHeading == "func render()")
        #expect(hunk.rows.map(\.kind) == [.context, .del, .add, .noNewline])
        #expect(hunk.rows[1].oldNo == 8 && hunk.rows[1].newNo == nil)
        #expect(hunk.rows[2].oldNo == nil && hunk.rows[2].newNo == 8)
        #expect(response.isBinary == false && response.tooLarge == false)
        #expect(response.nextCursor == 120)
    }

    @Test func decodesCapturedContextShape() throws {
        let data = Data(#"{"rows":["first line","","third line"]}"#.utf8)

        let response = try JSONDecoder().decode(MobileDiffContextResponse.self, from: data)

        #expect(response.rows == ["first line", "", "third line"])
    }
}
