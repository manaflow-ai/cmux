import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextUpdater
import Foundation
import Testing

@MainActor @Suite(.serialized) struct UpdateCardSettingsTests {
    @Test func cardSwitchWritesBothPreferencesAndRapidClicksKeepTheirOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "update-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(),
                                          fileURL: directory.appending(path: "cmux-next.json"),
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let updater = UpdaterService(enableSparkle: false, recordsUpdates: false)
        updater.writesSettings(to: settings)
        updater.setAutomaticUpdates(false)
        await updater.settingsWriteTask?.value
        #expect(!settings.snapshot.updates.downloadAutomatically)
        #expect(!settings.snapshot.updates.installWhenIdle)
        updater.setAutomaticUpdates(true)
        await updater.settingsWriteTask?.value
        #expect(settings.snapshot.updates.downloadAutomatically)
        #expect(settings.snapshot.updates.installWhenIdle)
        updater.setAutomaticUpdates(false)
        updater.setAutomaticUpdates(true)
        updater.setAutomaticUpdates(false)
        await updater.settingsWriteTask?.value
        #expect(!settings.snapshot.updates.downloadAutomatically)
        #expect(!settings.snapshot.updates.installWhenIdle)
        updater.apply(settings.snapshot.updates)
        #expect(!updater.automaticUpdates)
    }
}
