import SwiftUI
import Testing

@testable import CmuxSidebarUI

/// Locks in the lenient `Scanner.scanHexInt64` parsing of `sidebarHexColor`,
/// drained byte-identically from the app target's `extensionSidebarColor`. The
/// distinct sentinel `fallback` makes "parsed a color" observably different from
/// "returned the fallback": any parser swap that changes the accepted set (for
/// example routing through `Color(hex:)`'s strict `UInt64(_:radix:16)`) flips one
/// of these expectations.
@Suite("Color.sidebarHexColor")
struct ColorSidebarHexTests {
    private let fallback = Color(red: 0.123, green: 0.456, blue: 0.789)

    private func parsed(_ hex: String?) -> Bool {
        Color.sidebarHexColor(hex, fallback: fallback) != fallback
    }

    @Test("nil and wrong-length inputs return the fallback")
    func rejectsNilAndWrongLength() {
        #expect(!parsed(nil))
        #expect(!parsed(""))
        #expect(!parsed("fff"))
        #expect(!parsed("fffffff"))
    }

    @Test("plain 6-digit hex (with or without #) parses to a color")
    func acceptsPlainSixDigitHex() {
        #expect(parsed("ff00aa"))
        #expect(parsed("#ff00aa"))
        #expect(parsed("000000"))
        #expect(parsed("ABCDEF"))
    }

    @Test("byte-identical RGB for valid plain hex")
    func plainHexMatchesExpectedRGB() {
        #expect(Color.sidebarHexColor("ff00aa", fallback: fallback)
            == Color(red: 255.0 / 255.0, green: 0.0 / 255.0, blue: 170.0 / 255.0))
    }

    @Test("Scanner leniency is preserved: 0x prefix, embedded/leading/trailing whitespace, and trailing non-hex still parse")
    func preservesScannerLeniency() {
        // These all DIVERGE from a strict UInt64(_:radix:16) parser, which would
        // return the fallback. The lenient Scanner reads a hex prefix instead.
        #expect(parsed("0xff12"))
        #expect(parsed("0xAB12"))
        #expect(parsed("12345g"))
        #expect(parsed("ff 00a"))
        #expect(parsed("1234 5"))
        #expect(parsed(" 12345"))
        #expect(parsed("12345 "))
        #expect(parsed("12-345"))
        #expect(parsed("FF_F00"))
    }

    @Test("a leading + is rejected, matching Scanner (and diverging from UInt64 radix)")
    func rejectsLeadingPlus() {
        // UInt64("+12345", radix: 16) succeeds; Scanner.scanHexInt64 does not.
        #expect(!parsed("+12345"))
        #expect(!parsed("+f00aa"))
    }
}
