import CmuxNextFeatures
import Testing

/// A Debug tunable a feature `replaces` stays its local override, read at each use
/// (p12-perf-process-102: `motion.pane.holdContent`, `sidebar.slideHoldsContent`): step 3 of the order,
/// under policy and the environment lists, over the remote document and the channel default, never in Release.
struct FeatureListLiveLocalOverrideTests {
    private static let off = Feature(index: 0, name: "holdThing", owner: "PL-test", description: "A test feature.",
                                     kind: .perfPath, process: .app, chromiumFeature: nil, defaults: FeatureDefaults(all: false),
                                     expires: nil, params: [], stories: [], sticky: false, runtimeMutable: false)
    private static let on = Feature(index: 1, name: "slideThing", owner: "PL-test", description: "A test feature.",
                                    kind: .perfPath, process: .app, chromiumFeature: nil, defaults: FeatureDefaults(all: true),
                                    expires: nil, params: [], stories: [], sticky: false, runtimeMutable: false)
    private static let registry = FeatureRegistry([off, on])

    private func makeList(_ channel: Feature.Channel, _ overrides: FeatureOverrides = FeatureOverrides()) -> FeatureList {
        FeatureList(registry: Self.registry, channel: channel, overrides: overrides)
    }

    @Test(arguments: [Feature.Channel.dev, .nightly, .release])
    func withoutAnOverrideTheResolvedValueStands(channel: Feature.Channel) {
        let list = makeList(channel)
        #expect(!list.isEnabled(Self.off, overriddenBy: nil))
        #expect(list.isEnabled(Self.on, overriddenBy: nil))
    }

    @Test(arguments: [Feature.Channel.dev, .nightly])
    func theOverrideBeatsTheDefaultAndTheRemoteDocument(channel: Feature.Channel) {
        #expect(makeList(channel).isEnabled(Self.off, overriddenBy: true))
        #expect(!makeList(channel).isEnabled(Self.on, overriddenBy: false))
        let remote = makeList(channel, FeatureOverrides(remote: ["holdThing": true]))
        #expect(!remote.isEnabled(Self.off, overriddenBy: false))
    }

    @Test func releaseNeverAsksForTheOverride() {
        var asked = 0
        func readOverride() -> Bool? {
            asked += 1
            return true
        }
        let byDefault = makeList(.release).isEnabled(Self.off, overriddenBy: readOverride())
        let byRemote = makeList(.release, FeatureOverrides(remote: ["holdThing": true])).isEnabled(Self.off, overriddenBy: readOverride())
        #expect(!byDefault)
        #expect(byRemote)
        #expect(asked == 0)
    }

    @Test func policyAndTheEnvironmentBeatTheOverride() {
        #expect(!makeList(.dev, FeatureOverrides(policyDisabled: ["slideThing"])).isEnabled(Self.on, overriddenBy: true))
        #expect(!makeList(.dev, FeatureOverrides(environmentDisabled: ["holdThing"])).isEnabled(Self.off, overriddenBy: true))
        #expect(makeList(.nightly, FeatureOverrides(environmentEnabled: ["holdThing"])).isEnabled(Self.off, overriddenBy: false))
    }

    /// Each call reads the override again: a Debug change applies at the next spring or slide.
    @Test func eachCallReadsTheOverrideAgain() {
        let list = makeList(.dev)
        var value: Bool?
        #expect(!list.isEnabled(Self.off, overriddenBy: value))
        value = true
        #expect(list.isEnabled(Self.off, overriddenBy: value))
        value = nil
        #expect(!list.isEnabled(Self.off, overriddenBy: value))
    }

    /// The two motion holds keep their defaults as features: the pane hold off, the sidebar hold on, on every channel.
    @Test(arguments: [Feature.Channel.dev, .nightly, .release])
    func theMotionHoldsKeepTheirDefaults(channel: Feature.Channel) {
        let list = FeatureList(registry: FeatureRegistry(), channel: channel)
        #expect(!list.isEnabled(.paneHoldsContentInMotion))
        #expect(list.isEnabled(.sidebarSlideHoldsContent))
    }
}
