import Foundation
import Testing

@testable import CmuxFileSearch

@Suite("Streaming ripgrep output")
struct RipgrepStreamDecoderTests {
    private func output(files: [(String, Int)]) -> Data {
        var text = ""
        for (path, count) in files {
            text += #"{"type":"begin","data":{"path":{"text":"\#(path)"}}}"# + "\n"
            for line in 1...count {
                text += RipgrepFixture.matchLine(path: path, line: "hit needle\n", lineNumber: line, byteRanges: [4..<10]) + "\n"
            }
            text += #"{"type":"end","data":{"path":{"text":"\#(path)"}}}"# + "\n"
        }
        return Data(text.utf8)
    }

    @Test("Lines split across chunk borders decode once and stay grouped")
    func byteAtATime() {
        let data = output(files: [("/r/a", 3), ("/r/b", 2)])
        let decoder = RipgrepStreamDecoder(matchLimit: 100)
        var groups: [FileSearchFileMatches] = []
        for byte in data {
            groups.appendMerging(decoder.consume([byte]))
        }
        groups.appendMerging(decoder.finish())

        #expect(groups.map(\.path) == ["/r/a", "/r/b"])
        #expect(groups.map(\.matches.count) == [3, 2])
        #expect(decoder.matchCount == 5)
        #expect(!decoder.isLimitReached)
    }

    @Test("An unterminated final line is decoded by finish()")
    func trailingLine() {
        var data = output(files: [("/r/a", 1)])
        let match = RipgrepFixture.matchLine(path: "/r/z", line: "needle", lineNumber: 9, byteRanges: [0..<6])
        data.append(contentsOf: Array(match.utf8))
        let decoder = RipgrepStreamDecoder(matchLimit: 100)
        var groups = decoder.consume(data)
        groups.appendMerging(decoder.finish())

        #expect(groups.map(\.path) == ["/r/a", "/r/z"])
    }

    @Test("Exactly the limit completes; one more is limited and truncated")
    func limit() {
        let exact = RipgrepStreamDecoder(matchLimit: 4)
        _ = exact.consume(output(files: [("/r/a", 4)]))
        #expect(exact.matchCount == 4)
        #expect(!exact.isLimitReached)

        let over = RipgrepStreamDecoder(matchLimit: 4)
        let groups = over.consume(output(files: [("/r/a", 3), ("/r/b", 3)]))
        #expect(over.isLimitReached)
        #expect(over.matchCount == 4)
        #expect(groups.map(\.matches.count) == [3, 1])
        #expect(over.consume(output(files: [("/r/c", 1)])).isEmpty)
    }

    @Test("Exit statuses classify into completions", arguments: [
        (Int32(0), "", 3, false, FileSearchCompletion.completed),
        (1, "", 0, false, .completed),
        (2, "permission denied", 5, false, .completed),
        (2, "some failure", 0, false, .failed(.processFailed(status: 2, message: "some failure"))),
        (2, "regex parse error:\n    (\n    ^", 0, false, .failed(.invalidRegex("regex parse error:\n    (\n    ^"))),
        (127, "cmux-file-search: rg not found", 0, false, .failed(.ripgrepNotFound)),
        (143, "", 10, true, .limited(10)),
    ])
    func classification(status: Int32, stderr: String, matches: Int, limited: Bool, expected: FileSearchCompletion) {
        let completion = FileSearchCompletion(
            ripgrepExitStatus: status,
            standardError: stderr,
            matchCount: matches,
            limitReached: limited,
            matchLimit: 10
        )
        #expect(completion == expected)
    }
}
