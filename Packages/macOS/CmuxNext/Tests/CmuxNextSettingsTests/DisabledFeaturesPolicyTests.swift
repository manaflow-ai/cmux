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

    @Test func aRecommendedValueTurnsNothingOff() async throws {
        let (settings, registry, directory) = try controller(ManagedPreferences(recommended: ["DisabledFeatures": ["cloud"]]))
        defer { try? FileManager.default.removeItem(at: directory) }
        await settings.reload()
        #expect(registry.disabledFeatures.isEmpty)
    }
}
