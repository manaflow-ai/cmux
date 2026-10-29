import CmuxNextFeatures
import Testing

/// The daemon features the app's `client-hello` sends and their hash, which must
/// equal the daemon's `cmux_features::values_hash` (the Rust test `the_hash_is_fnv1a_of_the_ordered_values`).
struct FeatureListDaemonHelloTests {
    @Test func theHashMatchesTheDaemonVector() {
        #expect(FeatureList.daemonValuesHash([]) == "cbf29ce484222325")
        let values = [FeatureList.DaemonValue(name: "terminalHolder", isEnabled: false),
                      FeatureList.DaemonValue(name: "energySaver", isEnabled: true)]
        #expect(FeatureList.daemonValuesHash(values) == "40dd6db15aa26b63")
        #expect(FeatureList.daemonValuesHash(values.reversed()) != "40dd6db15aa26b63")
    }

    @Test func onlyDaemonAndBothFeaturesAreSentWithTheAppsValues() {
        let overrides = FeatureOverrides(environment: [FeatureOverrides.disableVariable: "terminalHolder"])
        let list = FeatureList(registry: FeatureRegistry(), channel: .release, overrides: overrides)
        let values = list.daemonValues
        let daemonSide = FeatureRegistry().features.filter { $0.process == .daemon || $0.process == .both }
        #expect(values.map(\.name) == daemonSide.map(\.name))
        #expect(values.first { $0.name == "terminalHolder" }?.isEnabled == false)
        #expect(list.daemonValuesHash == FeatureList.daemonValuesHash(values))
        #expect(list.daemonValuesHash != FeatureList(registry: FeatureRegistry(), channel: .release).daemonValuesHash)
    }
}
