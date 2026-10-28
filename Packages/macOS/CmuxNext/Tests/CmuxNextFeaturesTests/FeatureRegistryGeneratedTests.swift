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
}
