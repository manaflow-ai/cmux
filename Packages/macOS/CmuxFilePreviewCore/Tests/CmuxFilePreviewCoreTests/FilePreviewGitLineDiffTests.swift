import Foundation
import Testing

@testable import CmuxFilePreviewCore

@Suite("File Preview git line diff")
struct FilePreviewGitLineDiffTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let base: String
        let current: String
        let expected: [Int: FilePreviewGitLineChange]

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "identical text", base: "one\ntwo\n", current: "one\ntwo\n", expected: [:]),
        Case(name: "appended lines", base: "one\ntwo\n", current: "one\ntwo\nthree\nfour\n", expected: [3: .added, 4: .added]),
        Case(name: "insertion at the top", base: "one\n", current: "zero\none\n", expected: [1: .added]),
        Case(name: "insertion in the middle", base: "one\ntwo\n", current: "one\nnew\ntwo\n", expected: [2: .added]),
        Case(name: "replaced line", base: "one\ntwo\nthree\n", current: "one\nTWO\nthree\n", expected: [2: .modified]),
        Case(name: "replaced run", base: "a\nb\nc\nd\n", current: "a\nB\nC\nd\n", expected: [2: .modified, 3: .modified]),
        Case(name: "deleted first line", base: "one\ntwo\n", current: "two\n", expected: [1: .removed]),
        Case(name: "deleted middle line", base: "one\ntwo\nthree\n", current: "one\nthree\n", expected: [2: .removed]),
        Case(name: "deleted tail", base: "one\ntwo\nthree\n", current: "one\n", expected: [1: .removedAtEnd]),
        Case(name: "deleted everything", base: "one\ntwo\n", current: "", expected: [1: .removed]),
        Case(name: "new file", base: "", current: "one\ntwo\n", expected: [1: .added, 2: .added]),
        Case(name: "independent edits", base: "a\nb\nc\nd\ne\n", current: "a\nB\nc\ne\nf\n", expected: [2: .modified, 4: .removed, 5: .added]),
        Case(name: "missing final newline only", base: "one\ntwo\n", current: "one\ntwo", expected: [:]),
        Case(name: "CRLF versus LF only", base: "one\r\ntwo\r\n", current: "one\ntwo\n", expected: [:]),
        Case(name: "lone CR breaks count as lines", base: "a\rb\rc", current: "a\rB\rc", expected: [2: .modified]),
        Case(name: "Unicode separators count as lines", base: "a\u{2028}b\u{2029}c", current: "a\u{2028}b\u{2029}C", expected: [3: .modified]),
    ]

    @Test("Marks changed lines", arguments: cases)
    func marksChangedLines(_ testCase: Case) {
        #expect(FilePreviewGitLineDiff().changes(base: testCase.base, current: testCase.current) == testCase.expected)
    }

    @Test("Untracked gutter markers never carry changes")
    func untrackedMarkersDropChanges() {
        let markers = FilePreviewGitGutterMarkers(isTracked: false, changes: [1: .added])
        #expect(markers == .untracked)
        #expect(markers.changes.isEmpty)
    }

    @Test("A middle over the alignment budget is one modified run between the shared lines")
    func middleOverAlignmentBudgetIsOneRun() {
        let diff = FilePreviewGitLineDiff(maximumLineCount: 100, maximumByteCount: 1024, maximumAlignedLineCount: 2)
        let changes = diff.changes(base: "a\nb\nc\nd\n", current: "a\nX\nY\nZ\nd\n")
        #expect(changes == [2: .modified, 3: .modified, 4: .modified])
    }

    @Test("A fully rewritten large file is reported without aligning every line")
    func fullyRewrittenLargeFileIsBounded() {
        let base = (0..<5_000).map { "line \($0)\n" }.joined()
        let current = (0..<5_000).map { "    line \($0) reindented\n" }.joined()
        let changes = FilePreviewGitLineDiff().changes(base: base, current: current)
        #expect(changes.count == 5_000)
        #expect(changes.values.allSatisfy { $0 == .modified })
    }

    @Test("A cancelled caller gets no changes")
    func cancelledCallerGetsNoChanges() async {
        let changes = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return FilePreviewGitLineDiff().changes(base: "one\n", current: "two\n")
        }.value
        #expect(changes.isEmpty)
    }

    @Test("Skips input beyond the line budget")
    func skipsInputBeyondLineBudget() {
        let diff = FilePreviewGitLineDiff(maximumLineCount: 2, maximumByteCount: 1024)
        #expect(diff.changes(base: "one\n", current: "a\nb\nc\n").isEmpty)
        #expect(diff.changes(base: "one\n", current: "a\nb\n") == [1: .modified, 2: .modified])
    }

    @Test("Skips input beyond the byte budget")
    func skipsInputBeyondByteBudget() {
        let diff = FilePreviewGitLineDiff(maximumLineCount: 100, maximumByteCount: 4)
        #expect(diff.changes(base: "a\n", current: "abcde").isEmpty)
    }
}
