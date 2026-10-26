import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextFeatures
import CoreGraphics
import Testing

/// MQ6 (p12-perf-process-103): `hostPressure.enabled` and `hibernation.compressedSnapshots` became the features
/// `hostPressure` and `compressedSnapshots`. The readers read the feature; each toggle is only its feature's
/// local override (`FeatureList.isEnabled(_:localOverride:)`), and the defaults did not change.
@MainActor @Suite(.serialized)
struct HostPressureAndSnapshotFeatureTests {
    @Test func theFeatureDefaultsAreTheTogglesDefaults() {
        for channel in Feature.Channel.allCases {
            #expect(Feature.compressedSnapshots.defaults.value(for: channel) == HibernationTunables.compressedSnapshots.defaultValue)
            #expect(Feature.hostPressure.defaults.value(for: channel) == HostPressureTunables.enabled.defaultValue)
        }
    }

    private func indicator(_ overrides: FeatureOverrides, toggle: Bool?) -> (HostPressureIndicatorView, TunableStore) {
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        if let toggle { _ = store.set(HostPressureTunables.enabled.key, toggle.tunableValue) }
        let features = FeatureList(registry: FeatureRegistry(), channel: .dev, overrides: overrides)
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]), features: features)
        let indicator = HostPressureIndicatorView(
            services: services, store: store, notifications: NotificationCenter(), windowVisible: { _ in true },
            service: { HostPressureService(acpmux: nil, memoryPressure: { _ in (.normal, {}) }, store: store) }) {}
        return (indicator, store)
    }

    /// `CMUX_ENABLE_FEATURES=hostPressure` turns the indicator on with no toggle; managed policy keeps it off
    /// whatever the toggle says; with neither, the toggle decides, live.
    @Test func theIndicatorReadsTheFeature() {
        let name = Feature.hostPressure.name
        #expect(indicator(FeatureOverrides(environmentEnabled: [name]), toggle: nil).0.sampling.enabled)
        #expect(!indicator(FeatureOverrides(policyDisabled: [name]), toggle: true).0.sampling.enabled)
        let (live, store) = indicator(FeatureOverrides(), toggle: nil)
        #expect(!live.sampling.enabled, "the feature ships off")
        _ = store.set(HostPressureTunables.enabled.key, true.tunableValue)
        #expect(live.sampling.enabled, "the toggle is read live")
    }

    /// A hibernating page's picture is compressed while `keepsCompressed` says so, else decoded with no bytes.
    @Test func theSnapshotFollowsKeepsCompressed() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines)
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        hibernation.capture = { _ in image }
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        defer { tab.close() }
        let compressed = await hibernation.snapshot(tab, key: "a")
        #expect(compressed != nil && compressed?.data != nil, "the default keeps pictures compressed")
        hibernation.snapshots.keepsCompressed = { false }
        let decoded = await hibernation.snapshot(tab, key: "a")
        #expect(decoded != nil && decoded?.data == nil, "off keeps the decoded picture, with no bytes")
    }
}
