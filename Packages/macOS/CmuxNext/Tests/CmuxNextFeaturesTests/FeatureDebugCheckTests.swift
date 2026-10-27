import CmuxNextFeatures
import class CmuxSafeConcurrency.Invariant
import Testing

#if INVARIANT_REPORT
/// The nightly-assert variant (p10-stability-202) reaches an app module's debug checks: CmuxNextFeatures' checks are
/// `Invariant.debugCheck`, which report there, where the `assert()` they replaced was compiled out. Nothing in this
/// test process installs a sink into ``Invariant/process``, so a report is claimed and counted in
/// ``Invariant/undeliveredCount``. Run with
/// `swift test -c release -Xswiftc -DINVARIANT_REPORT --filter FeatureDebugCheckTests`.
struct FeatureDebugCheckTests {
    @Test func aRegistrySlotMismatchReportsInTheVariant() {
        let before = Invariant.process.undeliveredCount
        let registry = FeatureRegistry([Self.feature(index: 1, "misplacedThing")])
        #expect(registry.features.count == 1, "the variant reports and goes on")
        #expect(Invariant.process.undeliveredCount > before, "the feature-slot-matches check reported")
    }

    /// A test declaration at `index`: the fields the registry does not read take neutral values.
    private static func feature(index: Int, _ name: String) -> Feature {
        Feature(
            index: index,
            name: name,
            owner: "PL-test",
            description: "A test feature.",
            kind: .labs,
            process: .app,
            chromiumFeature: nil,
            defaults: FeatureDefaults(all: false),
            expires: nil,
            params: [],
            stories: [],
            sticky: false,
            runtimeMutable: false
        )
    }
}
#endif
