@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextWakeups
import Foundation
import Testing

/// The Debug tunable `browserResize.layerHosting` is only the local override of feature `cefLayerHosting`:
/// the launch reads it from the build's debug-tunables.json before its FeatureList
/// resolves, and the list itself puts it at step 3 (source `local`), under managed policy and the environment
/// lists, over the remote document and the channel default, never in Release. Every reader of the list (the engine,
/// `features.list`, the lab's arm record) sees the same value.
@MainActor @Suite(.serialized)
struct FeatureLaunchLocalOverridesTests {
    static let work = BackgroundWork(label: "test.feature-tunables")
    private static let tunable = BrowserResizeTunables.layerHosting.descriptor.key

    private func list(_ channel: Feature.Channel, _ overrides: FeatureOverrides = FeatureOverrides(),
                      tunable: Bool?, labs: [String: Bool] = [:]) -> FeatureList {
        FeatureList(registry: FeatureRegistry(), channel: channel, overrides: overrides,
                    local: FeatureLaunchLocalOverrides(labs: FeatureLocalOverrides(values: labs),
                                                       tunables: tunable.map { [Self.tunable: $0] } ?? [:]))
    }

    /// A debug-tunables.json holding `values`, in a folder of its own.
    private func tunablesFile(_ values: [String: Any]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "feature-tunables-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "debug-tunables.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "values": values]).write(to: file)
        return file
    }

    @Test func theFeatureReplacesTheTunable() {
        #expect(Feature.cefLayerHosting.replaces == [Self.tunable])
        #expect(FeatureLaunchLocalOverrides.replacedKeys(of: Feature.registered).contains(Self.tunable))
    }

    @Test func theTunableIsTheFeaturesLocalResolution() {
        for channel in [Feature.Channel.dev, .nightly] {
            let on = list(channel, tunable: true)
            #expect(on.isEnabled(.cefLayerHosting), "\(channel)")
            #expect(on.resolution(of: .cefLayerHosting) == Feature.Resolution(isEnabled: true, source: .local), "\(channel)")
            #expect(on.entries.contains { $0.feature == .cefLayerHosting && $0.resolution.source == .local })
            let off = list(channel, FeatureOverrides(remote: [Feature.cefLayerHosting.name: true]), tunable: false)
            #expect(off.resolution(of: .cefLayerHosting) == Feature.Resolution(isEnabled: false, source: .local),
                    "the tunable beats the remote document on \(channel)")
        }
        #expect(list(.dev, tunable: nil).resolution(of: .cefLayerHosting) == Feature.Resolution(isEnabled: false, source: .channelDefault))
    }

    @Test func releaseIgnoresTheTunable() {
        #expect(list(.release, tunable: true).resolution(of: .cefLayerHosting)
                == Feature.Resolution(isEnabled: false, source: .channelDefault))
        #expect(list(.release, FeatureOverrides(remote: [Feature.cefLayerHosting.name: true]), tunable: false)
            .resolution(of: .cefLayerHosting) == Feature.Resolution(isEnabled: true, source: .remote))
    }

    @Test func policyAndTheEnvironmentStillWin() {
        let name = Feature.cefLayerHosting.name
        #expect(list(.dev, FeatureOverrides(policyDisabled: [name]), tunable: true).resolution(of: .cefLayerHosting).source == .policy)
        #expect(!list(.dev, FeatureOverrides(environmentDisabled: [name]), tunable: true).isEnabled(.cefLayerHosting))
        #expect(list(.dev, FeatureOverrides(environmentEnabled: [name]), tunable: false).resolution(of: .cefLayerHosting)
                == Feature.Resolution(isEnabled: true, source: .environment))
    }

    @Test func aLabsChoiceBeatsTheTunable() {
        let name = Feature.cefLayerHosting.name
        #expect(!list(.dev, tunable: true, labs: [name: false]).isEnabled(.cefLayerHosting))
        #expect(list(.dev, tunable: false, labs: [name: true]).isEnabled(.cefLayerHosting))
    }

    @Test func theLaunchReadsOnlyReplacedBoolTunables() throws {
        let file = try tunablesFile([Self.tunable: true, "browserResize.syncDeadline": 0.004, "drop.overlay.style": "insetCard"])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let keys = FeatureLaunchLocalOverrides.replacedKeys(of: Feature.registered)
        #expect(TunableFile.boolValues(file, keys: keys) == [Self.tunable: true])
        let wrongType = try tunablesFile([Self.tunable: "yes"])
        defer { try? FileManager.default.removeItem(at: wrongType.deletingLastPathComponent()) }
        #expect(TunableFile.boolValues(wrongType, keys: keys).isEmpty)
        #expect(TunableFile.boolValues(file.appending(path: "missing"), keys: keys).isEmpty)
    }

    /// The file's value is the list's from the launch on, whenever the engine is built: the read ends on a launch
    /// lane before `launchFeatures` resolves, never through the tunable store's later main-actor load.
    @Test func theLaunchListTakesTheFileBeforeTheEngineIsBuilt() async throws {
        let file = try tunablesFile([Self.tunable: true])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var environment = AppEnvironment.current([:])
        let keys = FeatureLaunchLocalOverrides.replacedKeys(of: Feature.registered)
        let read = LaunchRead(on: Self.work) { TunableFile.boolValues(file, keys: keys) }
        environment.featureTunableOverrides = read
        _ = await read.finished()
        let features = AppServices.launchFeatures(environment)
        let expected = features.channel.allowsLocalOverrides
            ? Feature.Resolution(isEnabled: true, source: .local)
            : Feature.Resolution(isEnabled: false, source: .channelDefault)
        #expect(features.resolution(of: .cefLayerHosting) == expected)
    }
}
