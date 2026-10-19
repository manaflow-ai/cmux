import Foundation
import Testing

@testable import CmuxFilePreviewCore

extension Tag {
    @Tag static var filePreviewLargeInput: Self
}

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

    @Test("Recognizes Cocoa line separators and CRLF boundaries")
    func cocoaLineSeparatorsRemainIndexed() {
        let source = "one\r\ntwo\rthree\u{2028}four\u{2029}five"
        var index = FilePreviewLineIndex(string: source)
        #expect(index.lineStartOffsets == [0, 5, 9, 15, 20])

        // Collapsing CRLF to LF shifts the untouched suffix lazily.
        index.applyEdit(
            atUTF16Location: 3,
            replacingUTF16Length: 2,
            replacement: "\n"
        )
        #expect(index.lineStartOffsets == [0, 4, 8, 14, 19])

        // A standalone CR replacement remains a line break.
        index = FilePreviewLineIndex(string: "a\nb")
        index.applyEdit(
            atUTF16Location: 1,
            replacingUTF16Length: 1,
            replacement: "\r"
        )
        #expect(index.lineStartOffsets == [0, 2])
    }

    @Test("Extended separator edits remain equivalent to a rebuild")
    func extendedSeparatorEditsRemainEquivalent() {
        var index = FilePreviewLineIndex(string: "a\r\nb\r\nc\u{2028}d\u{2029}e")
        var mirror = "a\r\nb\r\nc\u{2028}d\u{2029}e"
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        let replacements = ["", "x", "\n", "y\n", "\r", "\r\n", "\u{2028}", "\u{2029}"]

        for _ in 0..<250 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let location = Int(state % UInt64(mirror.utf16.count + 1))
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let available = mirror.utf16.count - location
            let oldLength = available == 0 ? 0 : Int(state % UInt64(min(available, 3) + 1))
            state = state &* 6_364_136_223_846_793_005 &+ 1
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
            #expect(index.lineStartOffsets == FilePreviewLineIndex(string: mirror).lineStartOffsets)
            #expect(index.loadedUTF16Length == mirror.utf16.count)
        }
    }

    @Test(
        "Dense sixteen-megabyte input stays queryable",
        .tags(.filePreviewLargeInput),
        .timeLimit(.minutes(1))
    )
    func denseSixteenMegabyteInputStaysQueryable() {
        // This is intentionally the File Preview maximum, not a toy fixture:
        // it proves the block index remains bounded for the largest valid
        // dense document. The suite is serialized to contain its peak memory.
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

    @Test("Randomized edits across all Cocoa separators preserve queries")
    func randomizedCocoaSeparatorEditsPreserveQueries() {
        let alphabet = ["a", "\n", "\r", "\u{2028}", "\u{2029}"]
        let replacements = ["", "b", "\n", "\r", "\r\n", "\u{2028}", "\u{2029}", "x\r\ny"]
        var state: UInt64 = 0xA5A5_5A5A_1357_2468
        var mirror = "a\nb"
        var index = FilePreviewLineIndex(string: mirror)

        // Start on the ordinary LF path, then introduce a contextual
        // separator so later edits exercise the transition as well.
        mirror = (mirror as NSString).replacingCharacters(
            in: NSRange(location: 1, length: 1),
            with: "\r\n"
        )
        index.applyEdit(atUTF16Location: 1, replacingUTF16Length: 1, replacement: "\r\n")
        #expect(index.lineStartOffsets == FilePreviewLineIndex(string: mirror).lineStartOffsets)

        for _ in 0..<2_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            if mirror.utf16.count < 32, state & 3 == 0 {
                let insertion = alphabet[Int((state >> 8) % UInt64(alphabet.count))]
                let location = Int((state >> 16) % UInt64(mirror.utf16.count + 1))
                mirror = (mirror as NSString).replacingCharacters(
                    in: NSRange(location: location, length: 0),
                    with: insertion
                )
                index.applyEdit(
                    atUTF16Location: location,
                    replacingUTF16Length: 0,
                    replacement: insertion
                )
            } else {
                let location = Int((state >> 8) % UInt64(mirror.utf16.count + 1))
                let available = mirror.utf16.count - location
                let oldLength = available == 0 ? 0 : Int((state >> 16) % UInt64(min(available, 4) + 1))
                let replacement = replacements[Int((state >> 24) % UInt64(replacements.count))]
                mirror = (mirror as NSString).replacingCharacters(
                    in: NSRange(location: location, length: oldLength),
                    with: replacement
                )
                index.applyEdit(
                    atUTF16Location: location,
                    replacingUTF16Length: oldLength,
                    replacement: replacement
                )
            }

            let rebuilt = FilePreviewLineIndex(string: mirror)
            #expect(index.lineStartOffsets == rebuilt.lineStartOffsets)
            #expect(index.lineCount == rebuilt.lineCount)
            #expect(index.loadedUTF16Length == mirror.utf16.count)
            let query = Int((state >> 32) % UInt64(mirror.utf16.count + 8)) - 4
            #expect(index.lineNumber(containingUTF16Offset: query)
                == rebuilt.lineNumber(containingUTF16Offset: query))
        }
    }

    private func strings(ofLength length: Int, alphabet: [String]) -> [String] {
        guard length > 0 else { return [""] }
        return strings(ofLength: length - 1, alphabet: alphabet).flatMap { prefix in
            alphabet.map { prefix + $0 }
        }
    }
}
