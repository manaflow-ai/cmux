import CmuxFuzzSupport
import Foundation
import Testing
@testable import CmuxNextControl

/// Malformed control-socket input (any local process can write to the
/// socket): the JSON framing and the v1 text parser must answer an error or
/// parse, never trap. Seeded property tests on CmuxFuzzSupport (long mode:
/// CMUX_FUZZ_SECONDS).
@Suite struct ControlParserFuzzTests {
    static let pieces = ["{", "}", "[", "]", "\"", ":", ",", "method", "params", "id", "null", "true", "1e999", "-0",
                         "9223372036854775808", "\\u0000", "\\ud800", "--", "--x=", "=", "'", "\\", " ", "\u{0}", "é", "🙂", "\n"]

    /// One input of either property, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        if rng.bool() { randomLine(&rng) } else { invalidUTF8Line(&rng) }
    }

    static func randomLine(_ rng: inout FuzzRNG) {
        var line = ""
        for _ in 0..<rng.below(24) { line += pieces[rng.below(pieces.count)] }
        _ = ControlWire.decode(line)
    }

    static func invalidUTF8Line(_ rng: inout FuzzRNG) {
        let bytes = rng.bytes(48)
        _ = ControlWire.decode(String(decoding: bytes, as: UTF8.self))
    }

    @Test func randomLinesNeverTrap() throws {
        try FuzzRun("ControlParser.randomLines", seed: 0xDEAD_BEEF_CAFE_F00D, iterations: 20_000).forEach { rng in
            Self.randomLine(&rng)
        }
    }

    @Test func deepNestingIsRefusedOrParsed() {
        let deep = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
        _ = ControlWire.decode(deep)
        _ = ControlWire.decode("{\"method\":\"x\",\"params\":" + deep + "}")
    }

    @Test func invalidUTF8BytesNeverTrap() throws {
        try FuzzRun("ControlParser.invalidUTF8", seed: 7, iterations: 5_000).forEach { rng in
            Self.invalidUTF8Line(&rng)
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("ControlParser.oneInput", seed: 0xC0DE, iterations: 512)
        // Choice tapes, not JSON: a first byte picks the branch (odd: piece lines, even: raw bytes),
        // then a piece count and piece indices. [1, 7, 0, 4, 7, 4, 5, 10, 1] spells {"method":null}.
        let tapes: [[UInt8]] = [[0], [1], [1, 7, 0, 4, 7, 4, 5, 10, 1]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) }), Self.oneInput)
    }
}
