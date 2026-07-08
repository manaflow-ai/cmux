import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShellUI

@MainActor
@Suite struct DiffReviewSessionTests {
    @Test func hunkNavigationCrossesFileBoundary() {
        let session = DiffReviewSession(files: [
            file("A.swift"),
            file("B.swift"),
        ])
        session.recordHunkCount(2, for: "A.swift")
        session.recordHunkCount(3, for: "B.swift")

        session.moveForward()
        #expect(session.currentFile?.path == "A.swift")
        #expect(session.currentHunkIndex == 1)

        session.moveForward()
        #expect(session.currentFile?.path == "B.swift")
        #expect(session.currentHunkIndex == 0)

        session.moveBackward()
        #expect(session.currentFile?.path == "A.swift")
        #expect(session.currentHunkIndex == 1)
    }

    @Test func bookmarkJumpReturnsToTaggedFileAndHunk() {
        let session = DiffReviewSession(files: [
            file("A.swift"),
            file("B.swift"),
        ])
        session.recordHunkCount(2, for: "A.swift")
        session.recordHunkCount(2, for: "B.swift")
        session.moveForward()
        session.markBookmark()
        session.moveForward()

        #expect(session.hasJumpBackTarget)

        session.jumpToBookmark()

        #expect(session.currentFile?.path == "A.swift")
        #expect(session.currentHunkIndex == 1)
        #expect(!session.hasJumpBackTarget)
    }

    @Test func setFilesClampsSelection() {
        let session = DiffReviewSession(files: [file("A.swift"), file("B.swift")])
        session.openFile(at: 1)

        session.setFiles([file("A.swift")])

        #expect(session.currentFile?.path == "A.swift")
        #expect(session.currentHunkIndex == 0)
    }

    @Test func moveForwardDoesNotSkipFileBeforeHunksLoad() {
        let session = DiffReviewSession(files: [
            file("A.swift"),
            file("B.swift"),
        ])

        session.moveForward()

        #expect(session.currentFile?.path == "A.swift")
        #expect(session.currentHunkIndex == 0)

        session.recordHunkCount(0, for: "A.swift")
        session.moveForward()

        #expect(session.currentFile?.path == "B.swift")
        #expect(session.currentHunkIndex == 0)
    }

    private func file(_ path: String) -> MobileWorkspaceDiffStatusResponse.File {
        let data = Data(#"{"path":"\#(path)","status":"M","additions":1,"deletions":0}"#.utf8)
        return try! JSONDecoder().decode(MobileWorkspaceDiffStatusResponse.File.self, from: data)
    }
}
