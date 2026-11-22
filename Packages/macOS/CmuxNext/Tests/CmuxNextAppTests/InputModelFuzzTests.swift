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

    /// With a planted bug (a closed sheet that never reports it), a run
    /// buried in noise fails, and the shrinker keeps exactly the two
    /// actions that cause it, in order.
    @Test func shrinkerFindsTheMinimalSequence() throws {
        let noise: [FuzzAction] = [.frame, .type, .clickSidebar(window: 0, field: false), .clickPane(window: 0, pane: 1), .frame,
                                   .cmdL(window: 0), .escape(window: 0)]
        let actions = noise + [.openSheet(window: 0)] + noise + [.closeSheet(window: 0)] + noise
        let faulty = InputFuzzer.Config(windows: 1, reportsRemoval: false, fault: .sheetCloseUnreported)
        #expect(InputFuzzer.run(actions, config: InputFuzzer.Config(windows: 1, reportsRemoval: false)) == nil,
                "the same run without the fault is clean")
        let (violation, index) = try #require(InputFuzzer.run(actions, config: faulty))
        // The window keeps a sheet overlay AppKit no longer has: the world
        // check catches it (W3/W6, whichever it checks first).
        #expect([.overlaysMatch, .ghosttyMatches].contains(violation.invariant), "\(violation)")
        #expect(index == noise.count * 2 + 1, "it fails at the close")
        let minimal = InputFuzzer.shrink(actions, config: faulty, invariant: violation.invariant)
        #expect(minimal == [.openSheet(window: 0), .closeSheet(window: 0)])
    }
}
