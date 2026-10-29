import CmuxNextFeatures
import Testing

/// A dogfood build opens with its switch set on and no launch environment (handoff cmux-lead-dogfood-2.md): the set
/// applies by the shipped tag, sits under every other input, and reaches the daemons like any other override.
struct FeatureDogfoodSetTests {
    private static let labs = Feature(
        index: 0, name: "labsThing", owner: "PL-test", description: "A test feature.", kind: .labs, process: .app,
        chromiumFeature: nil, defaults: FeatureDefaults(all: false), expires: nil, params: [], stories: [], sticky: false,
        runtimeMutable: false)
    private static let other = Feature(
        index: 1, name: "otherThing", owner: "PL-test", description: "A test feature.", kind: .labs, process: .app,
        chromiumFeature: nil, defaults: FeatureDefaults(all: false), expires: nil, params: [], stories: [], sticky: false,
        runtimeMutable: false)
    private static let registry = FeatureRegistry([labs, other])
    private static let set = FeatureDogfoodSet(tagPrefix: "chrome-parity-", names: ["labsThing"])

    @Test func aDogfoodTagTurnsItsSetOnByDefault() {
        let list = FeatureList(registry: Self.registry, channel: .dev,
                               overrides: FeatureOverrides(environment: [:], buildDefaults: Self.set.buildDefaults(forTag: "chrome-parity-v2-1")))
        #expect(list.resolution(of: Self.labs) == Feature.Resolution(isEnabled: true, source: .buildDefault))
        #expect(list.resolution(of: Self.other) == Feature.Resolution(isEnabled: false, source: .channelDefault))
    }

    @Test func everyOtherBuildKeepsItsChannelDefaults() {
        for tag in [nil, "fix-resize", "chrome-paritya", "my-chrome-parity-v2"] as [String?] {
            #expect(Self.set.buildDefaults(forTag: tag).isEmpty, "tag \(tag ?? "nil")")
        }
    }

    @Test func theEnvironmentStillOverridesTheSetForOneLaunch() {
        let overrides = FeatureOverrides(environment: [FeatureOverrides.disableVariable: "labsThing"],
                                         buildDefaults: Self.set.buildDefaults(forTag: "chrome-parity-v2-1"))
        let list = FeatureList(registry: Self.registry, channel: .dev, overrides: overrides)
        #expect(list.resolution(of: Self.labs) == Feature.Resolution(isEnabled: false, source: .environment))
    }

    @Test func aDaemonFeatureTheSetTurnsOnReachesTheDaemon() {
        let list = FeatureList(registry: FeatureRegistry(), channel: .release,
                               overrides: FeatureOverrides(buildDefaults: ["leftoverDaemonIdleExit"]))
        #expect(list.isEnabled(.leftoverDaemonIdleExit))
        #expect(list.daemonEnvironment == [FeatureOverrides.enableVariable: "leftoverDaemonIdleExit"])
    }

    @Test func theChromeParitySetHasNoBenchOnlySwitch() {
        let names = FeatureDogfoodSet.chromeParity.names
        #expect(!names.isEmpty)
        for bench in ["perfLabCanary", "perfLabKillProbe", "cefLayerHostingEveryPage", "hangReportsSchema3"] {
            #expect(!names.contains(bench), "\(bench) is bench-only or turned on later")
        }
        #expect(!names.contains { $0.hasPrefix("perfLab") })
    }

    @Test func everyNameInTheChromeParitySetIsDeclared() {
        let registry = FeatureRegistry()
        let unknown = FeatureDogfoodSet.chromeParity.names.filter { registry.feature(named: $0) == nil }.sorted()
        #expect(unknown.isEmpty, "not declared in this build's registry: \(unknown)")
    }

    /// The chrome-parity dogfood builds keep the built-in ad blocker: with chromiumAdBlockerAtFirstTab on, a fork without
    /// the first-tab load (fork API 41; no pinned fork has it, 2026-10-28) runs no ad blocker, a regression Lawrence
    /// would see. The feature joins the set when a fork with API 41 is pinned.
    @Test func theChromeParitySetKeepsTheAdBlockerUntilAForkHasTheFirstTabLoad() {
        #expect(!FeatureDogfoodSet.chromeParity.names.contains("chromiumAdBlockerAtFirstTab"))
    }
}
