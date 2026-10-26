@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextFeatures
import Testing

/// The Debug tunable `browserResize.layerHosting` is only the local override of feature `cefLayerHosting`
/// (p12-perf-process-100): the App's bridge gives it the list's step 3, under managed policy and the
/// environment lists, over the remote document and the channel default, and never in Release.
@MainActor
struct CEFLayerHostingFeatureBridgeTests {
    private static let name = Feature.cefLayerHosting.name

    /// A private store (never the shared one) holding `value` for the tunable, or nothing.
    private func tunables(_ value: Bool?) -> TunableStore {
        let store = TunableStore()
        store.register(BrowserResizeTunables.all)
        store.activate(file: nil)
        store.set("browserResize.layerHosting", value.map(TunableValue.bool))
        return store
    }

    private func hosts(_ channel: Feature.Channel, _ overrides: FeatureOverrides = FeatureOverrides(), tunable: Bool?) -> Bool {
        let list = FeatureList(registry: FeatureRegistry(), channel: channel, overrides: overrides)
        return AppServices.cefLayerHosting(in: list, tunables: tunables(tunable))
    }

    @Test func withoutTheTunableTheFeatureDecides() {
        #expect(!hosts(.dev, tunable: nil), "the channel default stays off")
        #expect(!hosts(.nightly, tunable: nil))
        #expect(hosts(.dev, FeatureOverrides(environmentEnabled: [Self.name]), tunable: nil))
        #expect(hosts(.nightly, FeatureOverrides(remote: [Self.name: true]), tunable: nil))
    }

    @Test func theTunableOverridesTheDefaultAndTheRemoteDocumentOnDevAndNightly() {
        for channel in [Feature.Channel.dev, .nightly] {
            #expect(hosts(channel, tunable: true), "\(channel)")
            #expect(!hosts(channel, FeatureOverrides(remote: [Self.name: true]), tunable: false), "\(channel)")
        }
    }

    @Test func releaseNeverReadsTheTunable() {
        #expect(!hosts(.release, tunable: true))
        #expect(hosts(.release, FeatureOverrides(remote: [Self.name: true]), tunable: false))
    }

    @Test func policyAndTheEnvironmentBeatTheTunable() {
        #expect(!hosts(.dev, FeatureOverrides(policyDisabled: [Self.name]), tunable: true))
        #expect(!hosts(.dev, FeatureOverrides(environmentDisabled: [Self.name]), tunable: true))
        #expect(hosts(.dev, FeatureOverrides(environmentEnabled: [Self.name]), tunable: false))
    }
}
