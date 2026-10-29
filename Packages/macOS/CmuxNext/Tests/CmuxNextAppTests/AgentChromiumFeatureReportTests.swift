import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDesign
import CmuxNextFeatures
import Testing

/// `features.list` (and so the Labs card and a bench's recorded features) reports `agentChromium` as
/// `AppServices.agentChromiumChat` runs it: Debug Settings `agent.chromium` is its live local override
/// (source `local`) on DEV and NIGHTLY, and never under policy, the environment lists or in Release.
/// Run: `swift test --filter AgentChromiumFeatureReportTests`.
@MainActor
@Suite struct AgentChromiumFeatureReportTests {
    private static let name = Feature.agentChromium.name

    private static func tunables(chromium: Bool? = nil) -> TunableStore {
        let store = TunableStore()
        store.register(AgentPaneTunables.all)
        store.activate(file: nil)
        if let chromium { store.set(AgentPaneTunables.chromium.key, .bool(chromium)) }
        return store
    }

    private static func features(_ channel: Feature.Channel = .dev, _ overrides: FeatureOverrides = FeatureOverrides()) -> FeatureList {
        FeatureList(registry: FeatureRegistry(), channel: channel, overrides: overrides)
    }

    /// The value the app runs with: the seam's rule, with the same store the report reads.
    private static func runs(_ features: FeatureList, _ store: TunableStore) -> Bool {
        features.isEnabled(.agentChromium, localOverride: AgentPaneTunables.chromium.override(in: store))
    }

    @Test(arguments: [Feature.Channel.dev, .nightly])
    func theToggleOffIsTheReportedStateWithSourceLocal(_ channel: Feature.Channel) throws {
        let store = Self.tunables(chromium: false)
        let features = Self.features(channel)
        let report = FeatureFlagsPage.report(features, tunables: store, daemon: nil)
        #expect(report.resolution(of: .agentChromium) == Feature.Resolution(isEnabled: false, source: .local))
        #expect(Self.runs(features, store) == false)
        let rows = try #require(report.json["features"]?.arrayValue)
        let row = try #require(rows.first { $0["name"]?.stringValue == Self.name })
        #expect(row["state"]?.stringValue == "off")
        #expect(row["source"]?.stringValue == Feature.Source.local.description)
    }

    /// The report reads the toggle each time, as the seam does at each new page.
    @Test func theReportFollowsTheToggleAfterLaunch() {
        let store = Self.tunables()
        let features = Self.features(.dev)
        let report = FeatureFlagsPage.report(features, tunables: store, daemon: nil)
        for toggle in [true, false, nil] as [Bool?] {
            store.set(AgentPaneTunables.chromium.key, toggle.map(TunableValue.bool))
            let resolution = report.resolution(of: .agentChromium)
            #expect(resolution.isEnabled == Self.runs(features, store))
            #expect(resolution.source == (toggle == nil ? .channelDefault : .local))
        }
    }

    @Test func releaseReportsTheLaunchResolution() {
        let store = Self.tunables(chromium: false)
        let features = Self.features(.release)
        let report = FeatureFlagsPage.report(features, tunables: store, daemon: nil)
        #expect(report.resolution(of: .agentChromium) == features.resolution(of: .agentChromium))
        #expect(report.resolution(of: .agentChromium).isEnabled == Self.runs(features, store))
    }

    @Test func policyAndTheEnvironmentKeepTheirResolution() {
        let store = Self.tunables(chromium: true)
        for overrides in [FeatureOverrides(policyDisabled: [Self.name]), FeatureOverrides(environmentDisabled: [Self.name])] {
            let features = Self.features(.dev, overrides)
            let report = FeatureFlagsPage.report(features, tunables: store, daemon: nil)
            #expect(report.resolution(of: .agentChromium) == features.resolution(of: .agentChromium))
            #expect(report.resolution(of: .agentChromium).isEnabled == false)
            #expect(Self.runs(features, store) == false)
        }
        let enabled = Self.features(.dev, FeatureOverrides(environmentEnabled: [Self.name]))
        let offStore = Self.tunables(chromium: false)
        let report = FeatureFlagsPage.report(enabled, tunables: offStore, daemon: nil)
        #expect(report.resolution(of: .agentChromium) == Feature.Resolution(isEnabled: true, source: .environment))
        #expect(Self.runs(enabled, offStore))
    }
}
