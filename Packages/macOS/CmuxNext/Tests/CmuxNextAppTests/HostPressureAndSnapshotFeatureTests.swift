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

/// MQ6 (p12-perf-process-103): `hostPressure.enabled` and `hibernation.compressedSnapshots` became the features
/// `hostPressure` and `compressedSnapshots`. The readers read the launch's feature; each toggle is only its
/// feature's local override, which the launch reads from the Debug Settings file as step 3
/// (``FeatureLaunchLocalOverrides``), so `features.list` reports the value the code uses, with source `local`.
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

    /// A Debug Settings file's `values` as ``TunableFile/decode(_:)`` gives them: JSON booleans are CFBooleans.
    private static func tunablesFile(_ values: [String: Bool]) -> [String: Any] {
        values.mapValues { NSNumber(value: $0) }
    }

    private static func list(_ channel: Feature.Channel, _ overrides: FeatureOverrides = FeatureOverrides(),
                             labs: [String: Bool] = [:], toggles: [String: Bool]) -> FeatureList {
        let registry = FeatureRegistry()
        let local = FeatureLaunchLocalOverrides(labs: FeatureLocalOverrides(values: labs),
                                                toggles: FeatureLaunchLocalOverrides.toggles(in: tunablesFile(toggles), registry: registry))
        return FeatureList(registry: registry, channel: channel, overrides: overrides, local: local)
    }

    @Test func onlyAReplacedBoolToggleIsRead() {
        var raw = Self.tunablesFile([HostPressureTunables.enabled.key: true, HibernationTunables.compressedSnapshots.key: false])
        raw[HostPressureTunables.force.key] = "critical"
        #expect(FeatureLaunchLocalOverrides.toggles(in: raw, registry: FeatureRegistry())
            == [Feature.hostPressure.name: true, Feature.compressedSnapshots.name: false])
        let number: [String: Any] = [HostPressureTunables.enabled.key: NSNumber(value: 1)]
        #expect(FeatureLaunchLocalOverrides.toggles(in: number, registry: FeatureRegistry()).isEmpty, "a number is no toggle")
    }

    /// The finding this fixes: the toggle decided the code's value while `features.list` said `default`.
    @Test func theToggleIsTheResolutionAndTheReportShowsIt() throws {
        for channel in [Feature.Channel.dev, .nightly] {
            let features = Self.list(channel, toggles: [HostPressureTunables.enabled.key: true,
                                                        HibernationTunables.compressedSnapshots.key: false])
            #expect(features.resolution(of: .hostPressure) == Feature.Resolution(isEnabled: true, source: .local))
            #expect(features.resolution(of: .compressedSnapshots) == Feature.Resolution(isEnabled: false, source: .local))
            #expect(features.isEnabled(.hostPressure) && !features.isEnabled(.compressedSnapshots))
            let rows = try #require(FeatureFlagsReport(features: features).json["features"]?.arrayValue)
            let row = try #require(rows.first { $0["name"]?.stringValue == Feature.hostPressure.name })
            #expect(row["state"]?.stringValue == "on")
            #expect(row["source"]?.stringValue == "local")
        }
    }

    @Test func aLabsChoiceBeatsTheToggle() {
        let features = Self.list(.dev, labs: [Feature.hostPressure.name: false], toggles: [HostPressureTunables.enabled.key: true])
        #expect(features.resolution(of: .hostPressure) == Feature.Resolution(isEnabled: false, source: .local))
    }

    @Test func releaseNeverTakesTheToggle() {
        let features = Self.list(.release, toggles: [HostPressureTunables.enabled.key: true])
        #expect(features.resolution(of: .hostPressure) == Feature.Resolution(isEnabled: false, source: .channelDefault))
    }

    @Test func policyAndTheEnvironmentBeatTheToggle() {
        let name = Feature.hostPressure.name, on = [HostPressureTunables.enabled.key: true]
        #expect(Self.list(.dev, FeatureOverrides(policyDisabled: [name]), toggles: on).resolution(of: .hostPressure)
            == Feature.Resolution(isEnabled: false, source: .policy))
        #expect(Self.list(.dev, FeatureOverrides(environmentDisabled: [name]), toggles: on).resolution(of: .hostPressure)
            == Feature.Resolution(isEnabled: false, source: .environment))
        let off = [HibernationTunables.compressedSnapshots.key: false]
        #expect(Self.list(.nightly, FeatureOverrides(environmentEnabled: [Feature.compressedSnapshots.name]), toggles: off)
            .resolution(of: .compressedSnapshots) == Feature.Resolution(isEnabled: true, source: .environment))
    }

    /// The launch reads the toggles on the files lane, from the file the store writes.
    @Test func theLaunchReadsTheTogglesFromTheFile() async throws {
        let work = BackgroundWork(label: "test.feature-launch-toggles")
        let file = FileManager.default.temporaryDirectory.appending(path: "feature-toggles-\(UUID().uuidString).json")
        let read = { try await work.run(.userVisible, mayBlock: .files) { FeatureLaunchLocalOverrides.readToggles(file, registry: FeatureRegistry()) } }
        #expect(try await read().isEmpty, "no file is no toggle")
        let bytes = TunableFile.encode([HostPressureTunables.enabled.key: .bool(true)])
        try await work.run(.userVisible, mayBlock: .files) { try bytes.blockingWrite(to: file, options: .atomic) }
        #expect(try await read() == [Feature.hostPressure.name: true])
        try await work.run(.userVisible, mayBlock: .files) { try FileManager.checked.removeItem(at: file) }
    }

    private func indicator(_ overrides: FeatureOverrides) -> HostPressureIndicatorView {
        let store = TunableStore()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        let features = FeatureList(registry: FeatureRegistry(), channel: .dev, overrides: overrides)
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]), features: features)
        return HostPressureIndicatorView(
            services: services, store: store, notifications: NotificationCenter(), windowVisible: { _ in true },
            service: { HostPressureService(acpmux: nil, memoryPressure: { _ in (.normal, {}) }, store: store) }) {}
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
        #expect(compressed != nil && compressed?.data != nil, "the default keeps pictures compressed")
        hibernation.snapshots.keepsCompressed = false
        let decoded = await hibernation.snapshot(tab, key: "a")
        #expect(decoded != nil && decoded?.data == nil, "off keeps the decoded picture, with no bytes")
    }
}
