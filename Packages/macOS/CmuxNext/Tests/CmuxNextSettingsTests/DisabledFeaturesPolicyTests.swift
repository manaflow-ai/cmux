import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// `DisabledFeatures` reaches the registry from the forced managed layer
/// only: a user-writable non-forced value turns nothing off.
@MainActor @Suite struct DisabledFeaturesPolicyTests {
    func controller(_ managed: ManagedPreferences) throws -> (SettingsController, ActionRegistry, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-disabled-features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let registry = ActionRegistry.standard()
        let settings = SettingsController(registry: registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
        return (settings, registry, directory)
    }

    @Test func forcedDisabledFeaturesTurnActionsOff() async throws {
        let (settings, registry, directory) = try controller(ManagedPreferences(forced: ["DisabledFeatures": ["cloud", "computerUse", "notAFeature"]]))
        defer { try? FileManager.default.removeItem(at: directory) }
        await settings.reload()
        #expect(registry.disabledFeatures == [.cloud, .computerUse])
        #expect(!registry.isAvailable("newCloudMachine"))
    }

    /// Launch applies the forced value before any load, so Cloud, SSH and
    /// apps never start in the window before the first settings load.
    @Test func theForcedValueAppliesBeforeTheFirstLoad() throws {
        let (settings, registry, directory) = try controller(ManagedPreferences(forced: ["DisabledFeatures": ["remoteHosts"]]))
        defer { try? FileManager.default.removeItem(at: directory) }
        settings.applyManagedFeaturesNow()
        #expect(registry.disabledFeatures == [.remoteHosts])
    }

    @Test func aRecommendedValueTurnsNothingOff() async throws {
        let (settings, registry, directory) = try controller(ManagedPreferences(recommended: ["DisabledFeatures": ["cloud"]]))
        defer { try? FileManager.default.removeItem(at: directory) }
        await settings.reload()
        #expect(registry.disabledFeatures.isEmpty)
    }
}

/// A value the app cannot fully read never turns a feature on.
@Suite struct DisabledFeaturesValueTests {
    @Test func aMalformedValueTurnsEveryFeatureOff() {
        for value: JSONValue in ["cloud", .bool(true), ["cloud", .number(1)]] {
            let result = ManagedPreferences.disabledFeatures(in: ["DisabledFeatures": value])
            #expect(result.features == Set(ActionFeature.allCases), "\(value)")
            #expect(result.problem?.path == "DisabledFeatures")
        }
    }

    @Test func anUnknownNameIsReportedAndTheKnownOnesApply() {
        let result = ManagedPreferences.disabledFeatures(in: ["DisabledFeatures": ["cloud", "teleport"]])
        #expect(result.features == [.cloud])
        #expect(result.problem?.message.contains("teleport") == true)
    }

    @Test func noValueTurnsNothingOff() {
        let result = ManagedPreferences.disabledFeatures(in: [:])
        #expect(result.features.isEmpty && result.problem == nil)
    }
}
