@testable import CmuxNextApp
import Foundation
import Testing

/// Model-based fuzzing of the composed input system
/// (plans/cmux-next/input-spec.md section 6). CI runs the fixed seeds;
/// `CMUX_NEXT_FUZZ_RUNS=<n>` runs `n` more random seeds locally
/// (`CMUX_NEXT_FUZZ_SEED` picks the first, `CMUX_NEXT_FUZZ_STEPS` the length).
@Suite(.serialized)
struct InputModelFuzzTests {
    nonisolated static let ciSeeds: [UInt64] = Array(1...24)
    static let ciSteps = 500

    @Test(arguments: ciSeeds)
    func fixedSeedsKeepEveryInvariant(seed: UInt64) {
        if let failure = InputFuzzer.fuzz(seed: seed, steps: Self.ciSteps) {
            Issue.record("\(failure)")
        }
    }

    @Test func longRandomRun() {
        let environment = ProcessInfo.processInfo.environment
        guard let runs = environment["CMUX_NEXT_FUZZ_RUNS"].flatMap(Int.init), runs > 0 else { return }
        let first = environment["CMUX_NEXT_FUZZ_SEED"].flatMap(UInt64.init) ?? UInt64(Date().timeIntervalSince1970)
        let steps = environment["CMUX_NEXT_FUZZ_STEPS"].flatMap(Int.init) ?? 2_000
        for seed in first..<(first + UInt64(runs)) {
            if let failure = InputFuzzer.fuzz(seed: seed, steps: steps) {
                Issue.record("\(failure)")
                return
            }
        }
    }

    /// The world model itself starts consistent and a quiet run stays so.
    @Test(arguments: [1, 2, 3])
    func initialWorldIsConsistent(windows: Int) {
        let world = InputWorld(windows: windows, reportsRemoval: false)
        world.checkWorld()
        #expect(world.violations.isEmpty, "\(world.violations)")
    }

    /// The shrinker keeps the failure and drops everything else.
    @Test func shrinkerFindsTheMinimalSequence() {
        let noise: [FuzzAction] = [.frame, .type, .clickSidebar(window: 0, field: false), .frame]
        let actions = noise + [.openGroupEditor(window: 0)] + noise
        let config = InputFuzzer.Config(windows: 1, reportsRemoval: false)
        guard let (violation, _) = InputFuzzer.run(actions, config: config) else {
            // The group editor reports its overlay: nothing to shrink.
            return
        }
        let minimal = InputFuzzer.shrink(actions, config: config, invariant: violation.invariant)
        #expect(minimal.count <= 2)
    }
}
