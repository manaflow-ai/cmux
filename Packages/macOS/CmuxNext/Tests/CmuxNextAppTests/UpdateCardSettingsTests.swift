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

    @Test(arguments: [false, true])
    func managedFirstSettingDoesNotChangeTheOtherStepUnsafely(enabling: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "update-card-managed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux-next.json")
        // Enabling: managed download=false must not enable install. Disabling: managed
        // install=true must not prevent an otherwise permitted download opt-out.
        try Data(#"{"updates":{"downloadAutomatically":false,"installWhenIdle":false}}"#.utf8).write(to: url)
        let managedKey = enabling ? "updates.downloadAutomatically" : "updates.installWhenIdle"
        let forced = ManagedPreferences(forced: [managedKey: .bool(!enabling)])
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(),
                                          fileURL: url, managedReader: FixedManagedPreferenceReader(forced), managedWatchFiles: [])
        await settings.reload()
        if !enabling { try await settings.setSetting(at: UpdatesSettings.downloadAutomaticallyPath, to: .bool(true), by: .user) }
        let updater = UpdaterService(enableSparkle: false, recordsUpdates: false)
        updater.writesSettings(to: settings)
        updater.setAutomaticUpdates(enabling)
        await updater.settingsWriteTask?.value
        #expect(!settings.snapshot.updates.downloadAutomatically)
        #expect(settings.snapshot.updates.installWhenIdle == !enabling)
    }

}
