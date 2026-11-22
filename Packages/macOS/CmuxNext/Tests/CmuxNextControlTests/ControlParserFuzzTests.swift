import Foundation
import Testing
@testable import CmuxNextControl

/// Malformed control-socket input (any local process can write to the
/// socket): the JSON framing and the v1 text parser must answer an error or
/// parse, never trap.
@Suite struct ControlParserFuzzTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    static let pieces = ["{", "}", "[", "]", "\"", ":", ",", "method", "params", "id", "null", "true", "1e999", "-0",
                         "9223372036854775808", "\\u0000", "\\ud800", "--", "--x=", "=", "'", "\\", " ", "\u{0}", "é", "🙂", "\n"]

    @Test func randomLinesNeverTrap() {
        var rng = Rng(state: 0xDEAD_BEEF_CAFE_F00D)
        for _ in 0..<20_000 {
            var line = ""
            for _ in 0..<rng.below(24) { line += Self.pieces[rng.below(Self.pieces.count)] }
            _ = ControlWire.decode(line)
        }
    }

    @Test func deepNestingIsRefusedOrParsed() {
        let deep = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
        _ = ControlWire.decode(deep)
        _ = ControlWire.decode("{\"method\":\"x\",\"params\":" + deep + "}")
    }

    @Test func invalidUTF8BytesNeverTrap() {
        var rng = Rng(state: 7)
        for _ in 0..<5_000 {
            let bytes = (0..<rng.below(48)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            let line = String(decoding: bytes, as: UTF8.self)
            _ = ControlWire.decode(line)
        }
    }
}
