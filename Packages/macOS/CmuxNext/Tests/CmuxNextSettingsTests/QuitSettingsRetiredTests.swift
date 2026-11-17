@testable import CmuxNextSettings
import CmuxNextActions
import CmuxNextDesign
import Foundation
import Testing

/// One Quit (CMUX-630, Leo 2026-11-15: "we should just have the one quit and it's the same quit when i right click
/// the icon in the dock and it quits while keeping the background services alive. just less to think about"):
/// `app.quitBehavior` and `app.confirmQuit` are retired keys. An old file loads cleanly, Settings has no row for
/// either, and the launch migration takes both out of the file.
@MainActor @Suite(.serialized) struct QuitSettingsRetiredTests {
    @Test func anOldFileLoadsWithoutADiagnostic() {
        let root = JSONValue.object(["app": .object(["quitBehavior": .string("end-everything"), "confirmQuit": .bool(false)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("app.quitBehavior") || $0.path.hasPrefix("app.confirmQuit") })
        #expect(snapshot.retiredKeys == ["app.confirmQuit", "app.quitBehavior"])
    }

    @Test func settingsHasNoQuitRows() {
        for path in SettingsController.retiredQuitPaths {
            #expect(SettingsSchema.descriptor(for: path) == nil, Comment(rawValue: path.joined(separator: ".")))
            #expect(SettingsSchema.isRetired(path))
        }
    }

    @Test func theLaunchMigrationRemovesBothKeysAndKeepsTheRest() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-quit-retired-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(#"""
        {
          "app": { "quitBehavior": "end-keep-layout", "confirmQuit": false },
          "updates": { "installOnQuit": false }
        }
        """#.utf8).write(to: url)
        let settings = SettingsController(
            writer: TestSettingsWriter(),
            registry: ActionRegistry(catalog: []),
            design: DesignSettings(),
            fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
            managedWatchFiles: []
        )
        await settings.reload()

        #expect(try await settings.removeRetiredQuitSettings())
        for path in SettingsController.retiredQuitPaths {
            #expect(try await settings.file.value(at: path) == nil, Comment(rawValue: path.joined(separator: ".")))
        }
        // The `app` object they left empty goes too; other settings stay.
        #expect(try await settings.file.value(at: ["app"]) == nil)
        #expect(try await settings.file.value(at: ["updates", "installOnQuit"]) == .bool(false))
        // A second launch writes nothing.
        #expect(try await settings.removeRetiredQuitSettings() == false)
    }
}
