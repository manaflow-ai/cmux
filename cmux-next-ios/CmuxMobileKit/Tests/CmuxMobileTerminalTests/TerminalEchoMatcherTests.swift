import Foundation
import Testing
@testable import CmuxMobileTerminal

/// G-08: the real-link echo probe matches each typed byte with its echo.
@Suite struct TerminalEchoMatcherTests {
    @Test func eachTypedByteMatchesItsEchoInOrder() {
        var matcher = TerminalEchoMatcher()
        matcher.sent(Data("ls".utf8), at: 1.0)
        #expect(matcher.output(Data("l".utf8), at: 1.01).map(\.byte) == [UInt8(ascii: "l")])
        #expect(matcher.output(Data("\u{1B}[0m".utf8), at: 1.02).isEmpty)
        let echoed = matcher.output(Data("s".utf8), at: 1.03)
        #expect(echoed == [TerminalEchoMatcher.Key(byte: UInt8(ascii: "s"), sentAt: 1.0)])
        #expect(matcher.waiting.isEmpty)
    }

    @Test func controlBytesAreNotProbed() {
        var matcher = TerminalEchoMatcher()
        matcher.sent(Data([0x0D, 0x03, 0x1B]), at: 1)
        #expect(matcher.waiting.isEmpty)
    }

    @Test func anUnechoedByteExpiresAsLost() {
        var matcher = TerminalEchoMatcher()
        matcher.sent(Data("~".utf8), at: 1)
        #expect(matcher.output(Data("x".utf8), at: 1 + TerminalEchoMatcher.expiry + 0.1).isEmpty)
        #expect(matcher.lost == 1)
    }

    @Test func percentilesUseNearestRank() {
        let stats = TerminalEchoStats((1...100).map(Double.init))
        #expect(stats.n == 100 && stats.p50 == 50 && stats.p95 == 95 && stats.p99 == 99 && stats.max == 100)
    }
}

/// G-09: the text export joins soft-wrapped rows into their lines.
@Suite struct TerminalTextExportTests {
    @Test func softWrapsAreJoined() {
        let rows = TerminalScreenRows(rectangle: "abcd\nef\nxy", logical: "abcdef\nxy", columns: 4)
        #expect(rows.logicalText == "abcdef\nxy\n")
    }
}
