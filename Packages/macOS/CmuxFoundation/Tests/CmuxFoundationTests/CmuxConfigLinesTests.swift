import Foundation
import Testing
@testable import CmuxFoundation

/// Covers ``CmuxConfigLines``: the splitting, line-ending detection, and
/// rejoining that cmux's config editors share.
@Suite("Config line splitting and rejoining")
struct CmuxConfigLinesTests {
    private let configLines = CmuxConfigLines()

    @Test("Splits an LF body and its CRLF twin identically")
    func splitsLFAndCRLFIdentically() {
        let lf = "font-family = \"SF Mono\"\n\nsidebar-font-size = 12\n"

        #expect(configLines.split(lf) == ["font-family = \"SF Mono\"", "", "sidebar-font-size = 12"])
        #expect(
            configLines.split(lf.replacingOccurrences(of: "\n", with: "\r\n"))
                == configLines.split(lf)
        )
    }

    @Test("Leaves no carriage return for an exact marker comparison to trip over")
    func stripsCarriageReturnsSoMarkersCompareEqual() {
        let marker = "# cmux hooks begin"
        let splitLines = configLines.split("model = \"x\"\r\n\(marker)\r\nhooks = true\r\n")

        #expect(splitLines.contains(marker))
        #expect(splitLines == ["model = \"x\"", marker, "hooks = true"])
    }

    @Test("Drops the empty element a terminal newline leaves behind")
    func dropsTrailingEmptyElement() {
        #expect(configLines.split("a\n") == ["a"])
        #expect(configLines.split("a\r\n") == ["a"])
        #expect(configLines.split("a") == ["a"])
        #expect(configLines.split("a\n\n") == ["a", ""])
        #expect(configLines.split("a\r\n\r\n") == ["a", ""])
        #expect(configLines.split("") == [])
        #expect(configLines.split("\n") == [""])
        #expect(configLines.split("\r\n") == [""])
    }

    @Test("Finds the lines of a classic-Mac CR-only body")
    func splitsCROnlyBody() {
        #expect(configLines.split("a = 1\rb = 2\r") == ["a = 1", "b = 2"])
        #expect(configLines.split("a = 1\rb = 2") == ["a = 1", "b = 2"])
    }

    @Test("Reports the line ending of the first break in the body")
    func reportsLineEndingOfFirstBreak() {
        #expect(configLines.lineEnding(of: "a\nb\n") == .lf)
        #expect(configLines.lineEnding(of: "a\r\nb\r\n") == .crlf)
        #expect(configLines.lineEnding(of: "no newline here") == .lf)
        #expect(configLines.lineEnding(of: "") == .lf)
        // Mixed bodies follow whichever break comes first, lone CR included: a
        // later CRLF must not turn a CR- or LF-first body into a CRLF rewrite.
        #expect(configLines.lineEnding(of: "a\r\nb\nc") == .crlf)
        #expect(configLines.lineEnding(of: "a\nb\r\nc") == .lf)
        #expect(configLines.lineEnding(of: "a\rb\r\nc") == .lf)
        #expect(configLines.lineEnding(of: "a\rb\r") == .lf)
    }

    @Test("Rejoins with the requested ending and terminates the last line")
    func rejoinsWithRequestedEnding() {
        #expect(configLines.joined(["a", "b"]) == "a\nb\n")
        #expect(configLines.joined(["a", "b"], lineEnding: .crlf) == "a\r\nb\r\n")
        #expect(configLines.joined([]) == "")
        #expect(configLines.joined([], lineEnding: .crlf) == "")
    }

    @Test("Round-trips a config body unchanged, LF or CRLF")
    func roundTripsBodyUnchanged() {
        for body in ["a = 1\nb = 2\n", "a = 1\r\nb = 2\r\n", "a = 1\n\n\n", ""] {
            let roundTripped = configLines.joined(
                configLines.split(body),
                lineEnding: configLines.lineEnding(of: body)
            )
            #expect(roundTripped == body)
        }
    }
}
