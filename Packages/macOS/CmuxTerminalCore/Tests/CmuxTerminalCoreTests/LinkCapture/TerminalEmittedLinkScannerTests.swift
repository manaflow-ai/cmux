import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite
struct TerminalEmittedLinkScannerTests {
    @Test
    func capturesOSC8WithBELTerminator() {
        var scanner = TerminalEmittedLinkScanner()
        let links = scanner.consume(bytes("\u{1B}]8;;https://example.com/path\u{07}label\u{1B}]8;;\u{07}"))
        #expect(links == [
            TerminalCapturedLink(url: "https://example.com/path", source: .osc8)
        ])
    }

    @Test
    func capturesOSC8WithSTTerminator() {
        var scanner = TerminalEmittedLinkScanner()
        let links = scanner.consume(bytes("\u{1B}]8;;https://example.com/st\u{1B}\\label"))
        #expect(links == [
            TerminalCapturedLink(url: "https://example.com/st", source: .osc8)
        ])
    }

    @Test
    func capturesSplitOSC8URIAcrossChunks() {
        var scanner = TerminalEmittedLinkScanner()
        #expect(scanner.consume(bytes("\u{1B}]8;;https://exa")).isEmpty)
        #expect(scanner.consume(bytes("mple.com/split")).isEmpty)
        let links = scanner.consume(bytes("\u{1B}\\"))
        #expect(links == [
            TerminalCapturedLink(url: "https://example.com/split", source: .osc8)
        ])
    }

    @Test
    func capturesPlainURLsAtLinePositions() {
        var scanner = TerminalEmittedLinkScanner()
        let links = scanner.consume(bytes("""
https://start.example/a
see http://middle.example/b now
end https://end.example/c
""" + "\n"))
        #expect(links.map(\.url) == [
            "https://start.example/a",
            "http://middle.example/b",
            "https://end.example/c"
        ])
        #expect(links.allSatisfy { $0.source == .detected })
    }

    @Test
    func capturesURLSplitAcrossChunksWithinLogicalLine() {
        var scanner = TerminalEmittedLinkScanner()
        #expect(scanner.consume(bytes("open https://example.")).isEmpty)
        let links = scanner.consume(bytes("com/a/really/long/path\n"))
        #expect(links.map(\.url) == ["https://example.com/a/really/long/path"])
    }

    @Test
    func longUnwrappedLogicalLineCapturesCompleteURL() {
        var scanner = TerminalEmittedLinkScanner()
        let suffix = String(repeating: "a", count: 300)
        let url = "https://example.com/\(suffix)"
        let links = scanner.consume(bytes("value \(url)\n"))
        #expect(links.map(\.url) == [url])
    }

    @Test
    func stripsTrailingPunctuation() {
        let scanner = TerminalEmittedLinkScanner()
        #expect(scanner.detectURLs(in: "Go https://a.b/c, next") == ["https://a.b/c"])
        #expect(scanner.detectURLs(in: "Go https://a.b/c!?") == ["https://a.b/c"])
    }

    @Test
    func balancesParentheses() {
        let scanner = TerminalEmittedLinkScanner()
        #expect(scanner.detectURLs(in: "(https://a.b/c)") == ["https://a.b/c"])
        #expect(scanner.detectURLs(in: "https://a.b/c_(d)") == ["https://a.b/c_(d)"])
    }

    @Test
    func ignoresANSIColorAroundURLs() {
        var scanner = TerminalEmittedLinkScanner()
        let links = scanner.consume(bytes("\u{1B}[31mhttps://example.com/red\u{1B}[0m\n"))
        #expect(links.map(\.url) == ["https://example.com/red"])
    }

    @Test
    func capturesURLBeforeCRLF() {
        var scanner = TerminalEmittedLinkScanner()
        let links = scanner.consume(bytes("see https://example.com/crlf\r\n"))
        #expect(links.map(\.url) == ["https://example.com/crlf"])
    }

    @Test
    func carriageReturnOverwritesLine() {
        var scanner = TerminalEmittedLinkScanner()
        let links = scanner.consume(bytes("https://old.example\rhttps://new.example\n"))
        #expect(links.map(\.url) == ["https://new.example"])
    }

    @Test
    func lineCapOverflowDiscardsRestOfLine() {
        var scanner = TerminalEmittedLinkScanner()
        let overflow = String(repeating: "x", count: 4_200)
        let links = scanner.consume(bytes("\(overflow) https://example.com/nope\nhttps://example.com/yes\n"))
        #expect(links.map(\.url) == ["https://example.com/yes"])
    }

    @Test
    func noDetectionFastPathProducesNoLinks() {
        var scanner = TerminalEmittedLinkScanner()
        let links = scanner.consume(bytes(String(repeating: "plain output with no candidates ", count: 100) + "\n"))
        #expect(links.isEmpty)
    }

    @Test
    func resetPreventsSplitSequenceCapture() {
        var scanner = TerminalEmittedLinkScanner()
        #expect(scanner.consume(bytes("\u{1B}]8;;https://example.com/reset")).isEmpty)
        scanner.reset()
        let links = scanner.consume(bytes("\u{1B}\\\n"))
        #expect(links.isEmpty)
    }

    @Test
    func osc8URLLabelIsNotCountedAgainAsDetectedText() {
        var scanner = TerminalEmittedLinkScanner()
        let url = "https://example.com/same-label"
        let links = scanner.consume(bytes("\u{1B}]8;;\(url)\u{07}\(url)\u{1B}]8;;\u{07}\n"))

        #expect(links == [TerminalCapturedLink(url: url, source: .osc8)])
    }

    @Test
    func osc8URIsCountTowardLogicalLineCap() {
        var scanner = TerminalEmittedLinkScanner()
        let first = "https://first.example/" + String(repeating: "a", count: 1_400)
        let second = "https://second.example/" + String(repeating: "b", count: 1_400)
        let third = "https://third.example/" + String(repeating: "c", count: 1_400)
        let ignoredPlainURL = "https://ignored.example/after-overflow"
        let recoveredPlainURL = "https://recovered.example/next-line"
        let output = """
        \u{1B}]8;;\(first)\u{07}one\u{1B}]8;;\u{07}\
        \u{1B}]8;;\(second)\u{07}two\u{1B}]8;;\u{07}\
        \u{1B}]8;;\(third)\u{07}three\u{1B}]8;;\u{07}\
        \(ignoredPlainURL)
        \(recoveredPlainURL)
        """

        let links = scanner.consume(bytes(output))

        #expect(links.map(\.url) == [first, second, third, recoveredPlainURL])
    }

    @Test
    func controlSeparatorsDoNotMergeAdjacentURLs() {
        var scanner = TerminalEmittedLinkScanner()
        let links = scanner.consume(bytes("https://first.example/a\thttps://second.example/b\n"))

        #expect(links.map(\.url) == [
            "https://first.example/a",
            "https://second.example/b",
        ])
    }

    @Test
    func requiresPlausibleHostForDetectedURLs() {
        let scanner = TerminalEmittedLinkScanner()
        #expect(scanner.detectURLs(in: "http://example/path").isEmpty)
        #expect(scanner.detectURLs(in: "http://localhost:8080/path") == ["http://localhost:8080/path"])
        #expect(scanner.detectURLs(in: "http://127.0.0.1/path") == ["http://127.0.0.1/path"])
    }

    @Test
    func detectsBracketedIPv6URLs() {
        let scanner = TerminalEmittedLinkScanner()
        #expect(scanner.detectURLs(in: "open https://[2001:db8::1]/path") == [
            "https://[2001:db8::1]/path",
        ])
    }

    private func bytes(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }
}
