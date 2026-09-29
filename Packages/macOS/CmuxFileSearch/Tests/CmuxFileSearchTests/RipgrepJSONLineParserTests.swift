import Foundation
import Testing

@testable import CmuxFileSearch

@Suite("ripgrep JSON line parsing")
struct RipgrepJSONLineParserTests {
    @Test("A match line yields a 1-based UTF-16 column and a trimmed preview")
    func singleMatch() throws {
        let line = RipgrepFixture.matchLine(
            path: "/tmp/project/Sources/App.swift",
            line: "    let title = \"Search files\"\n",
            lineNumber: 42,
            byteRanges: [17..<23]
        )
        let group = try #require(RipgrepJSONLineParser.parseMatch(line: Array(line.utf8)))

        #expect(group.path == "/tmp/project/Sources/App.swift")
        #expect(group.matches.count == 1)
        let match = try #require(group.matches.first)
        #expect(match.lineNumber == 42)
        #expect(match.column == 18)
        #expect(match.length == 6)
        #expect(match.preview == "let title = \"Search files\"")
        #expect(match.highlightedText == "Search")
    }

    @Test("Every submatch on a line becomes its own match")
    func multipleSubmatches() throws {
        let line = RipgrepFixture.matchLine(
            path: "/p/a.txt",
            line: "foo bar foo baz foo\n",
            lineNumber: 3,
            byteRanges: [0..<3, 8..<11, 16..<19]
        )
        let group = try #require(RipgrepJSONLineParser.parseMatch(line: Array(line.utf8)))

        #expect(group.matches.map(\.column) == [1, 9, 17])
        #expect(group.matches.map(\.lineNumber) == [3, 3, 3])
        #expect(group.matches.map(\.highlightedText) == ["foo", "foo", "foo"])
    }

    @Test("Byte offsets after multibyte characters convert to UTF-16 columns")
    func multibyteOffsets() throws {
        // "é" is 2 UTF-8 bytes and 1 UTF-16 unit; "😀" is 4 bytes and 2 units.
        let text = "é😀 needle\n"
        let start = Array("é😀 ".utf8).count
        let line = RipgrepFixture.matchLine(
            path: "/p/u.txt",
            line: text,
            lineNumber: 1,
            byteRanges: [start..<(start + 6)]
        )
        let match = try #require(RipgrepJSONLineParser.parseMatch(line: Array(line.utf8))?.matches.first)

        #expect(match.column == 5)
        #expect(match.length == 6)
        #expect(match.highlightedText == "needle")
    }

    @Test("Valid UTF-8 bytes payloads decode like text payloads")
    func bytesPayload() throws {
        let line = try RipgrepFixture.matchLine(
            pathPayload: ["bytes": Data("/p/Bytes.swift".utf8).base64EncodedString()],
            linesPayload: ["bytes": Data("let needle = 1\n".utf8).base64EncodedString()],
            lineNumber: 7,
            byteRanges: [4..<10]
        )
        let group = try #require(RipgrepJSONLineParser.parseMatch(line: Array(line.utf8)))

        #expect(group.path == "/p/Bytes.swift")
        #expect(group.matches.first?.column == 5)
        #expect(group.matches.first?.highlightedText == "needle")
    }

    @Test("Invalid UTF-8 becomes U+FFFD without shifting the highlight")
    func invalidUTF8Bytes() throws {
        // 0x80 is a lone continuation byte before the match "oo".
        let bytes: [UInt8] = [0x66, 0x80, 0x6F, 0x6F, 0x0A]
        let line = try RipgrepFixture.matchLine(
            pathPayload: ["text": "/p/Invalid.bin"],
            linesPayload: ["bytes": Data(bytes).base64EncodedString()],
            lineNumber: 1,
            byteRanges: [2..<4]
        )
        let match = try #require(RipgrepJSONLineParser.parseMatch(line: Array(line.utf8))?.matches.first)

        #expect(match.preview.unicodeScalars.map(\.value) == [0x66, 0xFFFD, 0x6F, 0x6F])
        #expect(match.column == 3)
        #expect(match.highlightedText == "oo")
    }

    @Test("A long prefix is elided and the preview stays bounded")
    func longLineIsTrimmedAroundMatch() throws {
        let prefix = String(repeating: "a", count: 5_000)
        let suffix = String(repeating: "b", count: 5_000)
        let text = prefix + "needle" + suffix + "\n"
        let line = RipgrepFixture.matchLine(path: "/p/min.js", line: text, lineNumber: 1, byteRanges: [5_000..<5_006])
        let match = try #require(RipgrepJSONLineParser.parseMatch(line: Array(line.utf8))?.matches.first)

        #expect(match.column == 5_001)
        #expect(match.preview.hasPrefix("\u{2026}"))
        #expect(match.highlightedText == "needle")
        #expect(match.preview.utf16.count <= RipgrepJSONLineParser.previewMaximumLength + 1)
        #expect(match.previewMatchRange.lowerBound == RipgrepJSONLineParser.previewLeadingContext + 1)
    }

    @Test("Line endings are dropped and tabs render as spaces")
    func lineEndingsAndTabs() throws {
        let line = RipgrepFixture.matchLine(path: "/p/t.txt", line: "\tx\tneedle\r\n", lineNumber: 2, byteRanges: [3..<9])
        let match = try #require(RipgrepJSONLineParser.parseMatch(line: Array(line.utf8))?.matches.first)

        #expect(match.preview == "x needle")
        #expect(match.column == 4)
        #expect(match.highlightedText == "needle")
    }

    @Test("Non-match events are ignored", arguments: [
        #"{"type":"begin","data":{"path":{"text":"/p/a"}}}"#,
        #"{"type":"end","data":{"path":{"text":"/p/a"},"binary_offset":null,"stats":{}}}"#,
        #"{"type":"summary","data":{"elapsed_total":{"secs":0,"nanos":1}}}"#,
        #"{"type":"match","data":{"broken":true}}"#,
        "not json",
    ])
    func ignoresOtherEvents(line: String) {
        #expect(RipgrepJSONLineParser.parseMatch(line: Array(line.utf8)) == nil)
    }
}

extension FileSearchMatch {
    var highlightedText: String {
        let units = Array(preview.utf16)
        return String(decoding: units[previewMatchRange], as: UTF16.self)
    }
}

enum RipgrepFixture {
    static func matchLine(path: String, line: String, lineNumber: Int, byteRanges: [Range<Int>]) -> String {
        // swiftlint:disable:next force_try
        try! matchLine(pathPayload: ["text": path], linesPayload: ["text": line], lineNumber: lineNumber, byteRanges: byteRanges)
    }

    static func matchLine(
        pathPayload: [String: Any],
        linesPayload: [String: Any],
        lineNumber: Int,
        byteRanges: [Range<Int>]
    ) throws -> String {
        let payload: [String: Any] = [
            "path": pathPayload,
            "lines": linesPayload,
            "line_number": lineNumber,
            "absolute_offset": 0,
            "submatches": byteRanges.map { ["match": ["text": ""], "start": $0.lowerBound, "end": $0.upperBound] },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        // ripgrep always writes the type key first.
        return #"{"type":"match","data":"# + String(decoding: data, as: UTF8.self) + "}"
    }
}
