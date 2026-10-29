import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextWakeups
import CoreGraphics
import Foundation
import Testing

/// MQ6: `hostPressure.enabled` and `hibernation.compressedSnapshots` became the features
/// `hostPressure` and `compressedSnapshots`. The readers read the launch's feature; each toggle is only its
/// feature's local override, which the launch reads from the Debug Settings file as step 3
/// (`FeatureLaunchLocalOverrides`), so `features.list` reports the value the code uses, with source `local`.
@MainActor @Suite(.serialized)
struct HostPressureAndSnapshotFeatureTests {
    @Test func theFeatureDefaultsAreTheTogglesDefaults() {
        for channel in Feature.Channel.allCases {
            #expect(Feature.compressedSnapshots.defaults.value(for: channel) == HibernationTunables.compressedSnapshots.defaultValue)
            #expect(Feature.hostPressure.defaults.value(for: channel) == HostPressureTunables.enabled.defaultValue)
        }
    }

    @Test func eachFeatureReplacesItsToggle() {
        #expect(Feature.hostPressure.replaces == [HostPressureTunables.enabled.key])
        #expect(Feature.compressedSnapshots.replaces == [HibernationTunables.compressedSnapshots.key])
    }

    private static func list(_ channel: Feature.Channel, labs: [String: Bool] = [:], toggles: [String: Bool]) -> FeatureList {
        FeatureList(registry: FeatureRegistry(), channel: channel,
                    local: FeatureLaunchLocalOverrides(labs: FeatureLocalOverrides(values: labs), tunables: toggles))
    }

    /// The finding this fixes: the toggle decided the code's value while `features.list` said `default`.
    @Test func theTogglesAreTheResolutionAndTheReportShowsThem() throws {
        let toggles = [HostPressureTunables.enabled.key: true, HibernationTunables.compressedSnapshots.key: false]
        for channel in [Feature.Channel.dev, .nightly] {
            let features = Self.list(channel, toggles: toggles)
            #expect(features.resolution(of: .hostPressure) == Feature.Resolution(isEnabled: true, source: .local))
            #expect(features.resolution(of: .compressedSnapshots) == Feature.Resolution(isEnabled: false, source: .local))
            let rows = try #require(FeatureFlagsReport(features: features).json["features"]?.arrayValue)
            for (name, state) in [(Feature.hostPressure.name, "on"), (Feature.compressedSnapshots.name, "off")] {
                let row = try #require(rows.first { $0["name"]?.stringValue == name })
                #expect(row["state"]?.stringValue == state, "\(name)")
                #expect(row["source"]?.stringValue == "local", "\(name)")
            }
        }
        #expect(Self.list(.release, toggles: toggles).resolution(of: .hostPressure)
            == Feature.Resolution(isEnabled: false, source: .channelDefault))
        #expect(Self.list(.dev, labs: [Feature.hostPressure.name: false], toggles: toggles).resolution(of: .hostPressure)
            == Feature.Resolution(isEnabled: false, source: .local), "a Labs choice beats the toggle")
    }

    /// The launch reads both toggles on the files lane, from the file the store writes.
    @Test func theLaunchReadsBothToggles() async throws {
        let work = BackgroundWork(label: "test.feature-launch-toggles")
        let file = FileManager.default.temporaryDirectory.appending(path: "feature-toggles-\(UUID().uuidString).json")
        let bytes = TunableFile.encode([HostPressureTunables.enabled.key: .bool(true), HibernationTunables.compressedSnapshots.key: .bool(false),
                                        HostPressureTunables.force.key: .choice("critical")])
        let keys = FeatureLaunchLocalOverrides.replacedKeys(of: Feature.registered)
        let values = try await work.run(.userVisible, mayBlock: .files) {
            try bytes.blockingWrite(to: file, options: .atomic)
            defer { try? FileManager.checked.removeItem(at: file) }
            return TunableFile.boolValues(file, keys: keys)
        }
        #expect(values == [HostPressureTunables.enabled.key: true, HibernationTunables.compressedSnapshots.key: false])
    }

    private func indicator(_ overrides: FeatureOverrides) -> HostPressureIndicatorView {
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        let features = FeatureList(registry: FeatureRegistry(), channel: .dev, overrides: overrides)
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]), features: features)
        let rig = MainDeadlineRig(), node = VisibilityNode(root: "window", own: .visible)
        return HostPressureIndicatorView(
            services: services, store: store, mainWork: rig.deadlines.work, nodeOf: { _ in node },
            service: { hostPressureTestService(store, rig: rig) }) {}
    }

    /// `CMUX_ENABLE_FEATURES=hostPressure` turns the indicator on; managed policy and the default keep it off.
    @Test func theIndicatorReadsTheFeature() {
        let name = Feature.hostPressure.name
        #expect(indicator(FeatureOverrides(environmentEnabled: [name])).sampling.enabled)
        #expect(!indicator(FeatureOverrides(policyDisabled: [name])).sampling.enabled)
        #expect(!indicator(FeatureOverrides()).sampling.enabled, "the feature ships off")
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
        #expect(compressed?.isEncoded == true, "the default keeps pictures compressed")
        hibernation.snapshots.keepsCompressed = false
        let decoded = await hibernation.snapshot(tab, key: "a")
        #expect(decoded?.isEncoded == false, "off keeps the decoded picture, not encoded bytes")
    }
}
