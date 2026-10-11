@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Control socket input (crash program phase 3): target refs, envelope
/// prefixes, event cursors and durations from a client never trap.
@Suite struct ControlInputFuzzTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func text(_ alphabet: [Character], _ limit: Int) -> String {
            String((0..<below(limit)).map { _ in alphabet[below(alphabet.count)] })
        }
    }

    @Test func targetRefsAndEnvelopesParseOrThrowForAnyText() throws {
        var rng = Rng(state: 0xC0_17)
        let alphabet: [Character] = ["t", "a", "b", ":", " ", "-", "_", "w", "é", "1"]
        for _ in 0..<3_000 {
            let text = rng.text(alphabet, 16)
            _ = try? ControlRouter.target(from: .string(text), allowedKinds: ["tab"], knownKinds: ["tab", "workspace"], action: "x")
            let line = ["_cmux_capability_v1 ", "__cmux_automation_origin ", ""][rng.below(3)] + text
            #expect(line.hasSuffix(ControlAuthorizer.unwrapEnvelopes(line)))
        }
        #expect(ControlAuthorizer.unwrapEnvelopes("_cmux_capability_v1 abc rest") == "rest")
        #expect(ControlAuthorizer.unwrapEnvelopes("_cmux_capability_v1 abc") == "_cmux_capability_v1 abc")
        #expect(throws: ControlError.self) {
            try ControlRouter.target(from: "tab:", allowedKinds: ["tab"], knownKinds: ["tab"], action: "x")
        }
        #expect(try ControlRouter.target(from: "tab:a:b", allowedKinds: ["tab"], knownKinds: ["tab"], action: "x").id == "a:b")
    }

    /// Durations past Int.max milliseconds saturate (Int(seconds) * 1_000 trapped).
    @Test func durationMillisecondsSaturate() {
        #expect(Duration.seconds(Int64.max).wholeMilliseconds == Int.max)
        #expect(Duration.seconds(Int64.min).wholeMilliseconds == Int.min)
        #expect(Duration.milliseconds(1_500).wholeMilliseconds == 1_500)
    }

    @Test func eventCursorsAtIntegerBoundsSubscribe() {
        let bus = ControlEventBus(retainLimit: 3)
        _ = bus.publish(name: "n", category: "c", source: "s", payload: [:])
        for after: Int64? in [nil, .min, -1, 0, 1, .max] {
            bus.subscribe(after: after, names: [], categories: []).cancel()
        }
    }
}
