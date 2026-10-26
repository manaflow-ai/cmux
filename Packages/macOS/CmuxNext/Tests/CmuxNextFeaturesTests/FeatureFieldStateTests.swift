import CmuxNextFeatures
import Testing

/// A launch's features as hang reports and Sentry carry them (p12-perf-process-151): the hash of every
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

    /// The hash is SHA-256 over the sorted `name=on|off` lines (python3: hashlib.sha256(b"killThing=on\n
    /// labsThing=off\nperfThing=on\n").hexdigest()[:16]), so field.py and a bench result name the same arm.
    @Test func theHashIsTheValueOfEveryFeatureInNameOrder() {
        let state = Self.list().fieldState
        #expect(state.hash == "83e09a110533cd76")
        #expect(state.hash.count == FeatureFieldState.hashLength)
        #expect(state.nonDefault.isEmpty)
    }

    @Test func anOverrideIsListedWithItsStateAndSourceAndChangesTheHashOnlyWithTheValue() {
        let state = Self.list(FeatureOverrides(environmentEnabled: ["labsThing"], remote: ["killThing": true])).fieldState
        #expect(state.hash == "363b2a8f1f789985")
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
        #expect(state.hash == "895704b9f2500081")
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
}
