import CmuxFuzzSupport
import CmuxTerminalSizing
import Foundation
import Testing

/// Random operation sequences (crash program phase 3): attach, detach, report,
/// clear, activity and overrides on known and unknown ids never trap, and an
/// operation on an unknown id changes nothing. Seeded property tests on
/// CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS).
@Suite struct TerminalSizingOperationFuzzTests {
    static let ids = ["a", "b", "c", "d"]
    static let kinds: [TerminalDeviceKind] = [.mac, .iphone]

    /// One operation sequence, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        try operationSequence(&rng)
    }

    static func operationSequence(_ rng: inout FuzzRNG) throws {
        var engine = TerminalSizingEngine(initialSize: TerminalGridSize(cols: 80, rows: 24))
        for _ in 0..<40 {
            let id = ids[rng.below(ids.count)]
            let size = TerminalGridSize(cols: rng.below(400) - 20, rows: rng.below(200) - 10)
            switch rng.below(6) {
            case 0: engine.attach(TerminalSizingParticipant(id: id, deviceKind: kinds[rng.below(kinds.count)],
                                                            viewport: rng.below(3) == 0 ? nil : size))
            case 1: engine.detach(id)
            case 2: engine.report(id, viewport: size)
            case 3: engine.clearViewport(id)
            case 4: engine.noteActivity(id)
            default: engine.setCountsOverride(id, [true, false, nil][rng.below(3)])
            }
        }
        let before = engine.state
        let reported = engine.report("unknown", viewport: TerminalGridSize(cols: 10, rows: 10))
        let active = engine.noteActivity("unknown")
        let overridden = engine.setCountsOverride("unknown", true)
        let cleared = engine.clearViewport("unknown")
        try FuzzRun.check(!reported && !active && !overridden && !cleared, "an unknown id reported a change")
        try FuzzRun.check(engine.state == before, "an unknown id changed the state")
    }

    @Test func randomOperationsKeepTheEngineConsistent() throws {
        try FuzzRun("TerminalSizing.operations", seed: 0x51_2E, iterations: 300).forEach { rng in
            try Self.operationSequence(&rng)
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("TerminalSizing.oneInput", seed: 0x51_2F, iterations: 256)
        try run.forEachInput(run.corpus(seeds: [Data()]), Self.oneInput)
    }
}
