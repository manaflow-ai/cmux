import CmuxNextFeatures
import Testing

/// The checked-in registry (Features.generated.swift) is what every launch builds first: a slot that does not match its
/// index, or a name declared twice, stops the app in FeatureRegistry.init before any window (dogfood v2.2 on 2026-10-27,
/// after merges combined the generated file line by line). These read the list without that init's assert, so a bad
/// regeneration fails here with the offending names instead of trapping the test process.
struct FeatureRegistryGeneratedTests {
    @Test func everyRegisteredFeatureSitsAtItsOwnSlot() {
        let misplaced = Feature.registered.enumerated().filter { $0.element.index != $0.offset }
            .map { "\($0.element.name): index \($0.element.index) at slot \($0.offset)" }
        #expect(misplaced.isEmpty, "run scripts/cmux-next/gen-features.py: \(misplaced)")
    }

    @Test func noFeatureNameIsRegisteredTwice() {
        var seen = Set<String>()
        let twice = Feature.registered.map(\.name).filter { !seen.insert($0).inserted }
        #expect(twice.isEmpty, "run scripts/cmux-next/gen-features.py: \(twice)")
    }

    @Test func theLaunchRegistryBuilds() {
        #expect(FeatureRegistry().count == Feature.registered.count)
    }

    /// A perf lab switch exists only to be turned on by a bench (the canary's 2 ms key spin, the kill probe), so its
    /// default is off in every channel and a bench turns it on for one launch (cmux-ad, 2026-10-29: a kill probe that is on
    /// in release must never reach feat-cmux-next). The perf lab switches are the `perfLab` names; this test declares them
    /// (DEBUG builds compile the bench-only ones), so the rule is never checked against an empty list.
    @Test func noPerfLabSwitchIsOnByDefaultInAnyChannel() {
        let lab = Feature.registered.filter { $0.name.hasPrefix("perfLab") }
        #expect(!lab.isEmpty, "the perf lab switches are declared in DEBUG builds")
        let on = lab.filter { $0.defaults.dev || $0.defaults.nightly || $0.defaults.release }
            .map { "\($0.name): dev \($0.defaults.dev) nightly \($0.defaults.nightly) release \($0.defaults.release)" }
        #expect(on.isEmpty, "turn it off in its schemas/features/features.d JSON and enable it per launch: \(on)")
    }
}
