@testable import CmuxNextControl
import CmuxFuzzSupport
import CmuxNextSettings
import Foundation
import Testing

/// Control socket input (crash program phase 3): target refs, envelope
/// prefixes, event cursors and durations from a client never trap. Seeded
/// property tests on CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS).
@Suite struct ControlInputFuzzTests {
    static let alphabet: [Character] = ["t", "a", "b", ":", " ", "-", "_", "w", "é", "1"]

    /// One target ref and envelope, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        try targetRefAndEnvelope(&rng)
    }

    static func targetRefAndEnvelope(_ rng: inout FuzzRNG) throws {
        let text = rng.text(alphabet, 16)
        _ = try? ControlRouter.target(from: .string(text), allowedKinds: ["tab"], knownKinds: ["tab", "workspace"], action: "x")
        let line = ["_cmux_capability_v1 ", "__cmux_automation_origin ", ""][rng.below(3)] + text
        try FuzzRun.check(line.hasSuffix(ControlAuthorizer.unwrapEnvelopes(line)), "unwrapping \(line.debugDescription) kept no suffix")
    }

    @Test func targetRefsAndEnvelopesParseOrThrowForAnyText() throws {
        try FuzzRun("ControlInput.targetRefs", seed: 0xC0_17, iterations: 3_000).forEach { rng in
            try Self.targetRefAndEnvelope(&rng)
        }
        #expect(ControlAuthorizer.unwrapEnvelopes("_cmux_capability_v1 abc rest") == "rest")
        #expect(ControlAuthorizer.unwrapEnvelopes("_cmux_capability_v1 abc") == "_cmux_capability_v1 abc")
        #expect(throws: ControlError.self) {
            try ControlRouter.target(from: "tab:", allowedKinds: ["tab"], knownKinds: ["tab"], action: "x")
        }
        #expect(try ControlRouter.target(from: "tab:a:b", allowedKinds: ["tab"], knownKinds: ["tab"], action: "x").id == "a:b")
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("ControlInput.oneInput", seed: 0xC0_18, iterations: 512)
        // Choice tapes, not text: a length, alphabet indices, then the envelope.
        // [5, 0, 1, 2, 3, 1, 0] is "_cmux_capability_v1 tab:a".
        let tapes: [[UInt8]] = [[], [5, 0, 1, 2, 3, 1, 0]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) }), Self.oneInput)
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
