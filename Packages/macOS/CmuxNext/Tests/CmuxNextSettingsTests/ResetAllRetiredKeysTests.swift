@testable import CmuxNextSettings
import CmuxNextActions
import CmuxNextAppearance
import Foundation
import Testing

/// Reset All owns cleanup of keys that were removed from the active settings schema.
@MainActor @Suite(.serialized) struct ResetAllRetiredKeysTests {
    @Test func resetAllPrunesEveryRetiredKeyButKeepsUnknownKeys() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-reset-retired-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(#"""
        {
          "appearance": { "tabBarBackground": true },
          "updates": { "quietHours": "night" },
          "tabs": {
            "newTabKind": "terminal",
            "hiddenButtons": ["splitDown"],
            "tabBar": { "terminal": false, "browser": true, "agent": false }
          },
          "custom": { "keep": true }
        }
        """#.utf8).write(to: url)

        let settings = SettingsController(
            registry: ActionRegistry(catalog: []),
            design: DesignSettings(),
            fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
            managedWatchFiles: []
        )
        await settings.reload()

        try await settings.resetAllSettings(by: .user)

        for key in SettingsSchema.retiredKeys.keys {
            #expect(try await settings.file.value(at: CmuxConfigFile.keyPath(from: key)) == nil, Comment(rawValue: key))
        }
        #expect(try await settings.file.value(at: ["custom", "keep"]) == .bool(true))
    }
}
