import CmuxNextFeatures
import Testing

/// A Debug tunable a feature `replaces` is that feature's local override (p12-perf-process-102:
/// `motion.pane.holdContent`, `sidebar.slideHoldsContent`), resolved once per launch with source `local`: under policy
/// and the environment lists, over the remote document and the channel default, never in Release, and below the
/// Labs page's choice of the same feature.
/// Run: `swift test --filter FeatureTunableOverridesTests`.
struct FeatureTunableOverridesTests {
    private static let hold = Feature(index: 0, name: "holdThing", owner: "PL-test", description: "A test feature.",
                                      kind: .perfPath, process: .app, chromiumFeature: nil, defaults: FeatureDefaults(all: false),
                                      expires: nil, params: [], stories: [], sticky: false, runtimeMutable: false,
                                      replaces: ["motion.hold", "motion.holdOld"])
    private static let slide = Feature(index: 1, name: "slideThing", owner: "PL-test", description: "A test feature.",
                                       kind: .perfPath, process: .app, chromiumFeature: nil, defaults: FeatureDefaults(all: true),
                                       expires: nil, params: [], stories: [], sticky: false, runtimeMutable: false,
                                       replaces: ["sidebar.slide"])
    private static let registry = FeatureRegistry([hold, slide])

    private func makeList(_ channel: Feature.Channel, _ overrides: FeatureOverrides = FeatureOverrides(),
                          tunables: [String: Bool], labs: [String: Bool] = [:]) -> FeatureList {
        let local = FeatureLocalOverrideLayers([FeatureLocalOverrides(values: labs), FeatureTunableOverrides(values: tunables)])
        return FeatureList(registry: Self.registry, channel: channel, overrides: overrides, local: local)
    }

    @Test func aFeatureTakesItsFirstSetReplacedKey() {
        #expect(FeatureTunableOverrides(values: [:]).localOverride(for: Self.hold) == nil)
        #expect(FeatureTunableOverrides(values: ["motion.holdOld": true]).localOverride(for: Self.hold) == true)
        #expect(FeatureTunableOverrides(values: ["motion.hold": false, "motion.holdOld": true]).localOverride(for: Self.hold) == false)
        #expect(FeatureTunableOverrides(values: ["motion.hold": true]).localOverride(for: Self.slide) == nil, "another feature's key")
    }

    @Test(arguments: [Feature.Channel.dev, .nightly])
    func theTunableResolvesAsTheLocalOverride(channel: Feature.Channel) {
        let list = makeList(channel, tunables: ["motion.hold": true, "sidebar.slide": false])
        #expect(list.resolution(of: Self.hold) == Feature.Resolution(isEnabled: true, source: .local))
        #expect(list.resolution(of: Self.slide) == Feature.Resolution(isEnabled: false, source: .local))
        let remote = makeList(channel, FeatureOverrides(remote: ["holdThing": true]), tunables: ["motion.hold": false])
        #expect(remote.resolution(of: Self.hold) == Feature.Resolution(isEnabled: false, source: .local))
    }

    @Test func releaseNeverTakesTheTunable() {
        let list = makeList(.release, tunables: ["motion.hold": true, "sidebar.slide": false])
        #expect(list.resolution(of: Self.hold) == Feature.Resolution(isEnabled: false, source: .channelDefault))
        #expect(list.resolution(of: Self.slide) == Feature.Resolution(isEnabled: true, source: .channelDefault))
    }

    @Test func policyAndTheEnvironmentBeatTheTunable() {
        #expect(makeList(.dev, FeatureOverrides(policyDisabled: ["slideThing"]), tunables: ["sidebar.slide": true])
            .resolution(of: Self.slide) == Feature.Resolution(isEnabled: false, source: .policy))
        #expect(makeList(.nightly, FeatureOverrides(environmentEnabled: ["holdThing"]), tunables: ["motion.hold": false])
            .resolution(of: Self.hold) == Feature.Resolution(isEnabled: true, source: .environment))
    }

    /// The Labs page names the feature itself, so its choice wins over the Debug tunable it replaced.
    @Test func theLabsChoiceBeatsTheTunable() {
        let list = makeList(.dev, tunables: ["motion.hold": true], labs: ["holdThing": false])
        #expect(list.resolution(of: Self.hold) == Feature.Resolution(isEnabled: false, source: .local))
        #expect(makeList(.dev, tunables: ["motion.hold": true], labs: ["slideThing": false]).isEnabled(Self.hold),
                "a Labs choice of another feature leaves the tunable in place")
    }

    /// The two motion holds keep their defaults and name the tunables they replaced.
    @Test(arguments: [Feature.Channel.dev, .nightly, .release])
    func theMotionHoldsKeepTheirDefaults(channel: Feature.Channel) {
        let list = FeatureList(registry: FeatureRegistry(), channel: channel)
        #expect(!list.isEnabled(.paneHoldsContentInMotion))
        #expect(list.isEnabled(.sidebarSlideHoldsContent))
        #expect(Feature.paneHoldsContentInMotion.replaces == ["motion.pane.holdContent"])
        #expect(Feature.sidebarSlideHoldsContent.replaces == ["sidebar.slideHoldsContent"])
    }
}
