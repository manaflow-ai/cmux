import CmuxNextFeatures
import Testing

/// `FeatureList.isEnabled(_:localOverride:)` (p12-perf-process-103): a Debug toggle a feature replaced takes
/// step 3 of the ladder: DEV and NIGHTLY only, under policy and the environment lists, over the remote
/// document, the trial and the channel default.
struct FeatureListToggleOverrideTests {
    private static let thing = Feature(
        index: 0, name: "toggleThing", owner: "PL-test", description: "A test feature.", kind: .perfPath, process: .app,
        chromiumFeature: nil, defaults: FeatureDefaults(all: false), expires: nil, params: [], stories: [], sticky: false,
        runtimeMutable: false)
    private static let registry = FeatureRegistry([thing])

    private func isOn(_ channel: Feature.Channel, _ overrides: FeatureOverrides = FeatureOverrides(), toggle: Bool?) -> Bool {
        FeatureList(registry: Self.registry, channel: channel, overrides: overrides).isEnabled(Self.thing, localOverride: toggle)
    }

    @Test func noToggleIsTheListsValue() {
        #expect(!isOn(.dev, toggle: nil))
        #expect(isOn(.nightly, FeatureOverrides(remote: ["toggleThing": true]), toggle: nil))
        #expect(isOn(.release, FeatureOverrides(environmentEnabled: ["toggleThing"]), toggle: nil))
    }

    @Test func theToggleBeatsTheDefaultTheRemoteDocumentAndTheTrialOnDevAndNightly() {
        for channel in [Feature.Channel.dev, .nightly] {
            #expect(isOn(channel, toggle: true), "\(channel)")
            #expect(!isOn(channel, FeatureOverrides(remote: ["toggleThing": true]), toggle: false), "\(channel)")
        }
        #expect(!isOn(.nightly, FeatureOverrides(fieldTrial: ["toggleThing": true]), toggle: false))
    }

    @Test func releaseNeverTakesTheToggle() {
        #expect(!isOn(.release, toggle: true))
        #expect(isOn(.release, FeatureOverrides(remote: ["toggleThing": true]), toggle: false))
    }

    @Test func policyAndTheEnvironmentBeatTheToggle() {
        #expect(!isOn(.dev, FeatureOverrides(policyDisabled: ["toggleThing"]), toggle: true))
        #expect(!isOn(.dev, FeatureOverrides(environmentDisabled: ["toggleThing"]), toggle: true))
        #expect(isOn(.nightly, FeatureOverrides(environmentEnabled: ["toggleThing"]), toggle: false))
    }
}
