import Foundation
import Testing
@testable import CmuxStatusBar

@Suite("Status bar line reader")
struct StatusBarLineReaderTests {
    @Test func newestCompleteLineWinsAndTheTailWaitsForFinish() {
        var reader = StatusBarLineReader()
        #expect(reader.append(Data("a\nb\nc".utf8)) == "b")
        #expect(reader.finish() == "c")
        #expect(reader.finish() == nil)
    }

    @Test func lineSplitAcrossChunksIsJoined() {
        var reader = StatusBarLineReader()
        #expect(reader.append(Data("he".utf8)) == nil)
        #expect(reader.append(Data("llo\n".utf8)) == "hello")
    }

    @Test func blankLinesDoNotReplaceTheLastLine() {
        var reader = StatusBarLineReader()
        #expect(reader.append(Data("a\n\n\n".utf8)) == "a")
        #expect(reader.append(Data("\n".utf8)) == nil)
    }

    /// A line past the cap is cut there, and the rest of it does not turn
    /// into a line of its own.
    @Test func overlongLineIsCutAtTheCap() {
        var reader = StatusBarLineReader()
        let long = String(repeating: "x", count: StatusBarLineReader.maxLineBytes + 500)
        #expect(reader.append(Data(long.utf8)) == nil)
        #expect(reader.append(Data("yy\nnext\n".utf8)) == "next")

        #expect(reader.append(Data((long + "\n").utf8)) == String(repeating: "x", count: StatusBarLineReader.maxLineBytes))
    }

    @Test func unterminatedOutputStaysBounded() {
        var reader = StatusBarLineReader()
        for _ in 0..<64 {
            _ = reader.append(Data(repeating: UInt8(ascii: "z"), count: 4096))
        }
        #expect(reader.finish()?.utf8.count == StatusBarLineReader.maxLineBytes)
    }

    @Test func invalidUTF8IsReplacedNotDropped() {
        var reader = StatusBarLineReader()
        #expect(reader.append(Data([0x66, 0xff, 0x0a])) == "f\u{FFFD}")
    }
}
