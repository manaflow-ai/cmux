import Foundation
import Testing

@testable import CmuxFilePreviewCore

@Suite("File Preview line index", .serialized)
struct FilePreviewLineIndexTests {
    @Test("Counts logical lines and clamps lookups")
    func countsLogicalLines() {
        let empty = FilePreviewLineIndex(string: "")
        #expect(empty.lineCount == 1)
        #expect(empty.offset(forLine: 1) == 0)
        #expect(empty.lineNumber(containingUTF16Offset: 0) == 1)

        let index = FilePreviewLineIndex(string: "one\ntwo\nthree")
        #expect(index.lineCount == 3)
        #expect(index.offset(forLine: 1) == 0)
        #expect(index.offset(forLine: 3) == 8)
        #expect(index.offset(forLine: 99) == 8)
        #expect(index.lineNumber(containingUTF16Offset: 0) == 1)
        #expect(index.lineNumber(containingUTF16Offset: 8) == 3)
        #expect(index.lineNumber(containingUTF16Offset: 999) == 3)
    }

    @Test("Incremental edits match a full rebuild at every boundary")
    func incrementalEditsMatchFullRebuild() {
        var index = FilePreviewLineIndex(string: "alpha\nbeta\ngamma\ndelta")
        var mirror = "alpha\nbeta\ngamma\ndelta"

        func expectMirrored() {
            let rebuilt = FilePreviewLineIndex(string: mirror)
            #expect(index.lineStartOffsets == rebuilt.lineStartOffsets)
            #expect(index.lineCount == rebuilt.lineCount)
            #expect(index.loadedUTF16Length == rebuilt.loadedUTF16Length)
        }

        func edit(_ location: Int, _ oldLength: Int, _ replacement: String) {
            mirror = (mirror as NSString).replacingCharacters(
                in: NSRange(location: location, length: oldLength),
                with: replacement
            )
            index.applyEdit(
                atUTF16Location: location,
                replacingUTF16Length: oldLength,
                replacement: replacement
            )
            expectMirrored()
        }

        edit(5, 0, "\n")
        edit(0, 0, "// header\n")
        edit(6, 1, "X")
        edit(5, 1, "\n")
        edit(0, 11, "")
        edit(3, 4, "beta\nbeta\nbeta")

        let lineStart = (mirror as NSString).range(of: "beta\nbeta").location + 4
        edit(lineStart, 2, "\n")
        edit(lineStart - 1, 1, "gg")
        #expect(index.lineNumber(containingUTF16Offset: 2) == 1)
    }

    @Test("Retains a suffix line when an edit ends on its boundary")
    func preservesEndBoundary() {
        var index = FilePreviewLineIndex(string: "a\nb")
        index.applyEdit(atUTF16Location: 0, replacingUTF16Length: 2, replacement: "x")
        #expect(index.lineStartOffsets == [0])
        #expect(index.lineCount == 1)

        index = FilePreviewLineIndex(string: "a\nb")
        index.applyEdit(atUTF16Location: 0, replacingUTF16Length: 1, replacement: "")
        #expect(index.lineStartOffsets == [0, 1])
        #expect(index.lineCount == 2)
    }

    @Test("Lazy suffix shifts stay correct for edits near the start")
    func lazySuffixShifts() {
        let source = (0..<10_000).map(String.init).joined(separator: "\n")
        var index = FilePreviewLineIndex(string: source)
        var mirror = source

        for _ in 0..<40 {
            let replacement = "x"
            mirror = (mirror as NSString).replacingCharacters(
                in: NSRange(location: 0, length: 0),
                with: replacement
            )
            index.applyEdit(atUTF16Location: 0, replacingUTF16Length: 0, replacement: replacement)
        }

        let rebuilt = FilePreviewLineIndex(string: mirror)
        #expect(index.lineStartOffsets == rebuilt.lineStartOffsets)
        #expect(index.offset(forLine: 9_999) == rebuilt.offset(forLine: 9_999))
    }

    @Test("Randomized edits preserve every line start")
    func randomizedEditsPreserveLineStarts() {
        var index = FilePreviewLineIndex(string: "a\nb\nc\nd")
        var mirror = "a\nb\nc\nd"
        var state: UInt64 = 0x1234_5678_9ABC_DEF0

        for _ in 0..<250 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let location = Int(state % UInt64(mirror.utf16.count + 1))
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let available = mirror.utf16.count - location
            let oldLength = available == 0 ? 0 : Int(state % UInt64(min(available, 3) + 1))
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let replacements = ["", "x", "\n", "y\n"]
            let replacement = replacements[Int(state % UInt64(replacements.count))]

            mirror = (mirror as NSString).replacingCharacters(
                in: NSRange(location: location, length: oldLength),
                with: replacement
            )
            index.applyEdit(
                atUTF16Location: location,
                replacingUTF16Length: oldLength,
                replacement: replacement
            )

            let rebuilt = FilePreviewLineIndex(string: mirror)
            #expect(index.lineStartOffsets == rebuilt.lineStartOffsets)
            #expect(index.loadedUTF16Length == rebuilt.loadedUTF16Length)
        }
    }

    @Test("Edits use UTF-16 boundaries around supplementary characters")
    func editsRespectUTF16Boundaries() {
        var index = FilePreviewLineIndex(string: "😀\nsecond")
        var mirror = "😀\nsecond"

        // The emoji occupies two UTF-16 code units. Insert at the exact line
        // start after it, then replace the emoji's two-unit range.
        let lineStart = (mirror as NSString).range(of: "second").location
        mirror = (mirror as NSString).replacingCharacters(
            in: NSRange(location: lineStart, length: 0),
            with: "inserted\n"
        )
        index.applyEdit(
            atUTF16Location: lineStart,
            replacingUTF16Length: 0,
            replacement: "inserted\n"
        )
        #expect(index.lineStartOffsets == FilePreviewLineIndex(string: mirror).lineStartOffsets)

        mirror = (mirror as NSString).replacingCharacters(
            in: NSRange(location: 0, length: 2),
            with: "x"
        )
        index.applyEdit(atUTF16Location: 0, replacingUTF16Length: 2, replacement: "x")
        let rebuilt = FilePreviewLineIndex(string: mirror)
        #expect(index.lineStartOffsets == rebuilt.lineStartOffsets)
        #expect(index.loadedUTF16Length == mirror.utf16.count)
        #expect(index.lineNumber(containingUTF16Offset: 2) == 2)
    }

    @Test("Dense sixteen-megabyte input stays queryable")
    func denseSixteenMegabyteInputStaysQueryable() {
        let source = String(repeating: "\n", count: 16 * 1024 * 1024)
        let index = FilePreviewLineIndex(string: source)
        #expect(index.loadedUTF16Length == source.utf16.count)
        #expect(index.lineCount == source.utf16.count + 1)
        #expect(index.offset(forLine: index.lineCount) == source.utf16.count)
        #expect(index.lineNumber(containingUTF16Offset: source.utf16.count) == index.lineCount)
    }

    @Test("Exhaustive small edits preserve UTF-16 line starts")
    func exhaustiveSmallEditsPreserveLineStarts() {
        let alphabet = ["a", "\n"]
        let replacements = ["", "x", "\n", "y\n", "😀"]
        for length in 0...5 {
            for source in strings(ofLength: length, alphabet: alphabet) {
                let sourceLength = source.utf16.count
                for location in 0...sourceLength {
                    for oldLength in 0...(sourceLength - location) {
                        for replacement in replacements {
                            let edited = (source as NSString).replacingCharacters(
                                in: NSRange(location: location, length: oldLength),
                                with: replacement
                            )
                            var index = FilePreviewLineIndex(string: source)
                            index.applyEdit(
                                atUTF16Location: location,
                                replacingUTF16Length: oldLength,
                                replacement: replacement
                            )
                            let rebuilt = FilePreviewLineIndex(string: edited)
                            #expect(index.lineStartOffsets == rebuilt.lineStartOffsets)
                            #expect(index.loadedUTF16Length == edited.utf16.count)
                        }
                    }
                }
            }
        }
    }

    private func strings(ofLength length: Int, alphabet: [String]) -> [String] {
        guard length > 0 else { return [""] }
        return strings(ofLength: length - 1, alphabet: alphabet).flatMap { prefix in
            alphabet.map { prefix + $0 }
        }
    }
}
