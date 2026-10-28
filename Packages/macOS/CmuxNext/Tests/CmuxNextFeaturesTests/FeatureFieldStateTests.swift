@testable import CmuxNextFeatures
import Testing

/// A launch's features as hang reports and Sentry carry them: the hash of every
/// feature's value and the features an override decided, names only.
struct FeatureFieldStateTests {
    private static let perf = feature(0, "perfThing", FeatureDefaults(all: true))
    private static let kill = feature(1, "killThing", FeatureDefaults(all: true))
    private static let labs = feature(2, "labsThing", FeatureDefaults(all: false))
    private static let registry = FeatureRegistry([perf, kill, labs])

    private static func feature(_ index: Int, _ name: String, _ defaults: FeatureDefaults) -> Feature {
        Feature(index: index, name: name, owner: "PL-test", description: "A test feature.", kind: .perfPath, process: .app,
                chromiumFeature: nil, defaults: defaults, expires: nil, params: [], stories: [], sticky: false,
                runtimeMutable: false)
    }

    private static func list(_ overrides: FeatureOverrides = FeatureOverrides()) -> FeatureList {
        FeatureList(registry: registry, channel: .nightly, overrides: overrides)
    }

    /// The hash is 64-bit FNV-1a over the sorted `name=on|off` lines (offset basis 0xcbf29ce484222325, prime
    /// 0x100000001b3, the bytes of "killThing=on\nlabsThing=off\nperfThing=on\n"), so any reader can recompute it.
    @Test func theHashIsTheValueOfEveryFeatureInNameOrder() {
        let state = Self.list().fieldState
        #expect(state.hash == "5051faf05b4f8ec6")
        #expect(state.hash.count == FeatureFieldState.hashLength)
        #expect(state.nonDefault.isEmpty)
    }

    @Test func anOverrideIsListedWithItsStateAndSourceAndChangesTheHashOnlyWithTheValue() {
        let state = Self.list(FeatureOverrides(environmentEnabled: ["labsThing"], remote: ["killThing": true])).fieldState
        #expect(state.hash == "d88b099507379aca")
        #expect(state.nonDefault == [
            FeatureFieldState.Entry(name: "killThing", isEnabled: true, source: .remote),
            FeatureFieldState.Entry(name: "labsThing", isEnabled: true, source: .environment),
        ])
        #expect(state.nonDefault.map(\.description) == ["killThing=on@remote", "labsThing=on@env"])
        // killThing's remote value is its default: the arm that runs is the same, and so is the hash.
        #expect(Self.list(FeatureOverrides(environmentEnabled: ["labsThing"])).fieldState.hash == state.hash)
    }

    @Test func aPolicyOffIsAnOverride() {
        let state = Self.list(FeatureOverrides(policyDisabled: ["killThing"])).fieldState
        #expect(state.hash == "632bcd2a8ba9d39a")
        #expect(state.nonDefault.map(\.description) == ["killThing=off@policy"])
    }

    @Test func theHashDoesNotDependOnRegistryOrder() {
        let reordered = FeatureRegistry([
            Self.feature(0, "labsThing", FeatureDefaults(all: false)),
            Self.feature(1, "perfThing", FeatureDefaults(all: true)),
            Self.feature(2, "killThing", FeatureDefaults(all: true)),
        ])
        #expect(FeatureList(registry: reordered, channel: .nightly).fieldState == Self.list().fieldState)
    }

    @Test func aSmallHashKeepsItsLeadingZeros() {
        #expect(FeatureFieldState.hex(0xab) == "00000000000000ab")
        #expect(FeatureFieldState.hex(.max) == "ffffffffffffffff")
    }
}
