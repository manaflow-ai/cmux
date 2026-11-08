import Testing

@testable import CmuxAgentChat

@Suite("TerminalArtifactTapHitTester")
struct TerminalArtifactTapHitTesterTests {
    @Test("stitches a path wrapped across two rows from its head")
    func stitchesTwoRowsFromHead() {
        let path = "/tmp/artvw-project/notes.md"
        let columns = path.count - 1
        let text = Self.softWrapped(path, columns: columns)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) == [
            String(path.dropLast()),
            "d",
        ])

        let resolved = TerminalArtifactTapHitTester().path(
            in: text,
            col: 8,
            row: 0,
            columns: columns
        )

        #expect(resolved == path)
    }

    @Test("stitches when a trailing period fills the head row")
    func stitchesAfterTrailingPeriod() {
        let head = "/tmp/artvw-project/notes."
        let text = "\(head)\nmd remaining-output"

        let resolved = TerminalArtifactTapHitTester().path(
            in: text,
            col: 8,
            row: 0,
            columns: head.count
        )

        #expect(resolved == "/tmp/artvw-project/notes.md")
    }

    @Test("trims punctuation after stitching a trailing period boundary")
    func trimsFinalPunctuationAfterTrailingPeriod() {
        let head = "/tmp/artvw-project/notes."
        let text = "\(head)\nmd), remaining-output"

        let resolved = TerminalArtifactTapHitTester().path(
            in: text,
            col: 8,
            row: 0,
            columns: head.count
        )

        #expect(resolved == "/tmp/artvw-project/notes.md")
    }

    @Test("stitches a path wrapped across three rows")
    func stitchesThreeRows() {
        let path = "/tmp/a-very-long-project-name/another-folder/report.md"
        let columns = (path.count + 2) / 3
        let text = Self.softWrapped(path, columns: columns)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == 3)

        let resolved = TerminalArtifactTapHitTester().path(
            in: text,
            col: 2,
            row: 0,
            columns: columns
        )

        #expect(resolved == path)
    }

    @Test("leaves a non-wrapped path unchanged")
    func leavesNormalPathUnchanged() {
        let path = "/tmp/notes.md"

        let resolved = TerminalArtifactTapHitTester().path(
            in: "open \(path)",
            col: 7,
            row: 0,
            columns: 40
        )

        #expect(resolved == path)
    }

    @Test("resolves a bare filename referenced by terminal transcript prose")
    func resolvesBareFilename() {
        let resolved = TerminalArtifactTapHitTester().path(
            in: "Inspect data.csv, then continue.",
            col: 10,
            row: 0,
            columns: 80
        )

        #expect(resolved == "data.csv")
    }

    @Test("trims sentence punctuation from a bare filename")
    func trimsBareFilenamePunctuation() {
        let resolved = TerminalArtifactTapHitTester().path(
            in: "The log is build.log.",
            col: 15,
            row: 0,
            columns: 80
        )

        #expect(resolved == "build.log")
    }

    @Test("uses terminal cell width for CJK text before a path")
    func cjkPrefixUsesTerminalColumns() {
        let path = "/tmp/note.txt"

        let resolved = TerminalArtifactTapHitTester().path(
            in: "漢字 open \(path)",
            col: 22,
            row: 0,
            columns: 80
        )

        #expect(resolved == path)
    }

    @Test("does not stitch a full-width token to a new prompt")
    func doesNotStitchPrompt() {
        let path = "/tmp/exact.md"
        let columns = path.count
        let text = "\(path)\n$ next-command"

        let resolved = TerminalArtifactTapHitTester().path(
            in: text,
            col: 2,
            row: 0,
            columns: columns
        )

        #expect(resolved == path)
    }

    @Test("does not stitch a full-width non-path line to a new word")
    func doesNotStitchNonPathLineToNewWord() {
        let line = "plain-output"
        let text = "\(line)\ncontinuation"

        let resolved = TerminalArtifactTapHitTester().path(
            in: text,
            col: 2,
            row: 0,
            columns: line.count
        )

        #expect(resolved == nil)
    }

    @Test("resolves a continuation-row tap to the full path")
    func resolvesContinuationRowTap() {
        let path = "/tmp/artvw-project/notes.md"
        let columns = path.count - 1
        let text = Self.softWrapped(path, columns: columns)
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(rows.count == 2)

        let resolved = TerminalArtifactTapHitTester().path(
            in: text,
            col: 0,
            row: 1,
            columns: columns
        )

        #expect(resolved == path)
    }

    private static func softWrapped(_ text: String, columns: Int) -> String {
        var rows: [String] = []
        var remaining = text[...]
        while !remaining.isEmpty {
            let end = remaining.index(remaining.startIndex, offsetBy: columns, limitedBy: remaining.endIndex)
                ?? remaining.endIndex
            rows.append(String(remaining[..<end]))
            remaining = remaining[end...]
        }
        return rows.joined(separator: "\n")
    }
}
