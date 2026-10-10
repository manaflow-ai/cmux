import CmuxTerminalSizing
import Foundation
import Testing

/// Random operation sequences (crash program phase 3): attach, detach, report,
/// clear, activity and overrides on known and unknown ids never trap, and an
/// operation on an unknown id changes nothing.
@Suite struct TerminalSizingOperationFuzzTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    @Test func randomOperationsKeepTheEngineConsistent() {
        var rng = Rng(state: 0x51_2E)
        let ids = ["a", "b", "c", "d"]
        let kinds: [TerminalDeviceKind] = [.mac, .iphone]
        for _ in 0..<300 {
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
            #expect(!reported && !active && !overridden && !cleared)
            #expect(engine.state == before)
        }
    }
}
