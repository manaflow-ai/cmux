import Foundation
import Testing

@testable import CmuxFilePreviewCore

@Suite("File Preview git line diff")
struct FilePreviewGitLineDiffTests {
    @Test("Identical text produces no markers")
    func identicalTextProducesNoMarkers() {
        let text = "one\ntwo\nthree\n"
        #expect(FilePreviewGitLineDiff.changes(base: text, current: text).isEmpty)
    }

    @Test("Appended lines are added")
    func appendedLinesAreAdded() {
        let changes = FilePreviewGitLineDiff.changes(
            base: "one\ntwo\n",
            current: "one\ntwo\nthree\nfour\n"
        )
        #expect(changes == [3: .added, 4: .added])
    }

    @Test("Inserted line in the middle is added without touching neighbors")
    func insertedLineInMiddleIsAdded() {
        let changes = FilePreviewGitLineDiff.changes(
            base: "one\ntwo\nthree\n",
            current: "one\ninserted\ntwo\nthree\n"
        )
        #expect(changes == [2: .added])
    }

    @Test("Replaced line is modified rather than added plus removed")
    func replacedLineIsModified() {
        let changes = FilePreviewGitLineDiff.changes(
            base: "one\ntwo\nthree\n",
            current: "one\nTWO\nthree\n"
        )
        #expect(changes == [2: .modified])
    }

    @Test("A replaced run marks every replacement line")
    func replacedRunMarksEveryLine() {
        let changes = FilePreviewGitLineDiff.changes(
            base: "one\ntwo\nthree\nfour\n",
            current: "one\nTWO\nTHREE\nfour\n"
        )
        #expect(changes == [2: .modified, 3: .modified])
    }

    @Test("Deleted middle line anchors to the following line")
    func deletedMiddleLineAnchorsToFollowingLine() {
        let changes = FilePreviewGitLineDiff.changes(
            base: "one\ntwo\nthree\n",
            current: "one\nthree\n"
        )
        #expect(changes == [2: .removed])
    }

    @Test("Deletion at the end anchors to the last surviving line")
    func deletionAtEndAnchorsToLastLine() {
        let changes = FilePreviewGitLineDiff.changes(
            base: "one\ntwo\nthree\n",
            current: "one\n"
        )
        #expect(changes == [1: .removedAtEnd])
    }

    @Test("Deleting every line yields no marker because no line survives")
    func deletingEveryLineYieldsNoMarker() {
        let changes = FilePreviewGitLineDiff.changes(
            base: "one\ntwo\n",
            current: ""
        )
        #expect(changes.isEmpty)
    }

    @Test("A new file marks every line as added")
    func newFileMarksEveryLineAsAdded() {
        let changes = FilePreviewGitLineDiff.changes(
            base: "",
            current: "one\ntwo\n"
        )
        #expect(changes == [1: .added, 2: .added])
    }

    @Test("Separate edits keep independent markers")
    func separateEditsKeepIndependentMarkers() {
        let changes = FilePreviewGitLineDiff.changes(
            base: "a\nb\nc\nd\ne\n",
            current: "a\nB\nc\ne\nf\n"
        )
        #expect(changes == [2: .modified, 4: .removed, 5: .added])
    }

    @Test("A trailing newline difference alone is not a change")
    func trailingNewlineAloneIsNotAChange() {
        #expect(
            FilePreviewGitLineDiff.changes(base: "one\ntwo\n", current: "one\ntwo").isEmpty
        )
    }

    @Test("CRLF line endings do not read as modifications")
    func crlfLineEndingsDoNotReadAsModifications() {
        #expect(
            FilePreviewGitLineDiff.changes(
                base: "one\r\ntwo\r\n",
                current: "one\ntwo\n"
            ).isEmpty
        )
    }

    @Test("Input beyond the line budget is skipped")
    func inputBeyondLineBudgetIsSkipped() {
        let big = String(repeating: "line\n", count: FilePreviewGitLineDiff.maximumLineCount + 1)
        #expect(FilePreviewGitLineDiff.changes(base: "one\n", current: big).isEmpty)
    }

    @Test("Input beyond the byte budget is skipped without splitting lines")
    func inputBeyondByteBudgetIsSkipped() {
        let big = String(repeating: "x", count: FilePreviewGitLineDiff.maximumByteCount + 1)
        #expect(FilePreviewGitLineDiff.changes(base: "one\n", current: big).isEmpty)
    }
}
