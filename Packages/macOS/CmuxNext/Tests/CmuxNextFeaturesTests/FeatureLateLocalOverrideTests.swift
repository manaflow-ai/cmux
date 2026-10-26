import CmuxNextFeatures
import Testing

/// A Debug tunable a feature replaced is its local override, passed at each decision because its file
/// loads after the list is built (`FeatureList.isEnabled(_:localOverride:)`, p12-perf-process-104 for
/// `agent.chromium` -> `agentChromium`): step 3, under managed policy and the environment lists, over the
/// remote document, the field trial and the channel default, and never in Release.
/// Run: `swift test --filter FeatureLateLocalOverrideTests`.
struct FeatureLateLocalOverrideTests {
    private static let name = Feature.agentChromium.name

    private func enabled(_ channel: Feature.Channel, _ overrides: FeatureOverrides = FeatureOverrides(), tunable: Bool?) -> Bool {
        FeatureList(registry: FeatureRegistry(), channel: channel, overrides: overrides)
            .isEnabled(.agentChromium, localOverride: tunable)
    }

    @Test func agentChromiumKeepsTheTunablesDefaultOnEveryChannel() {
        for channel in Feature.Channel.allCases {
            #expect(Feature.agentChromium.defaults.value(for: channel), "\(channel)")
            #expect(enabled(channel, tunable: nil), "\(channel)")
        }
        #expect(Feature.agentChromium.kind == .perfPath)
        #expect(!Feature.agentChromium.runtimeMutable)
    }

    @Test(arguments: [Feature.Channel.dev, .nightly])
    func theOverrideBeatsTheDefaultTheRemoteDocumentAndTheTrial(_ channel: Feature.Channel) {
        #expect(!enabled(channel, tunable: false))
        #expect(enabled(channel, FeatureOverrides(remote: [Self.name: false]), tunable: true))
        #expect(!enabled(channel, FeatureOverrides(fieldTrial: [Self.name: true]), tunable: false))
    }

    @Test func releaseTakesNoOverride() {
        #expect(enabled(.release, tunable: false))
        #expect(!enabled(.release, FeatureOverrides(remote: [Self.name: false]), tunable: true))
    }

    /// The one rule both readers call: the seam's value and `features.list`'s live `local` row.
    @Test func theEffectiveOverrideIsNilWhereTheOverrideDoesNotApply() {
        let dev = FeatureList(registry: FeatureRegistry(), channel: .dev, overrides: FeatureOverrides())
        #expect(dev.effectiveLocalOverride(.agentChromium, localOverride: false) == false)
        #expect(dev.effectiveLocalOverride(.agentChromium, localOverride: nil) == nil)
        let notTaken: [(Feature.Channel, FeatureOverrides)] = [
            (.release, FeatureOverrides()), (.dev, FeatureOverrides(policyDisabled: [Self.name])),
            (.dev, FeatureOverrides(environmentDisabled: [Self.name])), (.nightly, FeatureOverrides(environmentEnabled: [Self.name])),
        ]
        for (channel, overrides) in notTaken {
            let list = FeatureList(registry: FeatureRegistry(), channel: channel, overrides: overrides)
            #expect(list.effectiveLocalOverride(.agentChromium, localOverride: false) == nil, "\(channel)")
        }
    }

    @Test func policyAndTheEnvironmentBeatTheOverride() {
        #expect(!enabled(.dev, FeatureOverrides(policyDisabled: [Self.name]), tunable: true))
        #expect(!enabled(.dev, FeatureOverrides(environmentDisabled: [Self.name]), tunable: true))
        #expect(enabled(.dev, FeatureOverrides(environmentEnabled: [Self.name]), tunable: false))
        let both = FeatureOverrides(environmentDisabled: [Self.name], environmentEnabled: [Self.name])
        #expect(!enabled(.dev, both, tunable: true), "a name on both lists is off, as in Chrome")
    }
}
