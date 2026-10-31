@testable import CmuxNextSettings
import CmuxNextActions
import CmuxNextDesign
import Foundation
import Testing

/// `updates.downloadAutomatically` is opt-in on stable and on by default in NIGHTLY and DEV. The
/// channel default fills the effective settings only: cmux-next.json is shared by every channel,
/// so nothing is written there, and a value someone wrote always wins.
@MainActor @Suite(.serialized) struct SettingsBuildDefaultsTests {
    private static func settings(_ json: String, _ defaults: SettingsBuildDefaults) async throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-build-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [],
                                          buildDefaults: defaults)
        await settings.reload()
        return (settings, home)
    }

    @Test func theDogfoodDefaultFillsTheEffectiveSettingsOnly() async throws {
        let (settings, home) = try await Self.settings("{}", .channel(downloadsAutomatically: true))
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(settings.snapshot.updates.downloadAutomatically, "NIGHTLY and DEV download by default")
        #expect(settings.fileRoot.value(at: UpdatesSettings.downloadAutomaticallyPath) == nil, "the channel default counted as the person's")
        #expect(try await settings.file.value(at: UpdatesSettings.downloadAutomaticallyPath) == nil, "the channel default was written to the shared file")
    }

    /// An explicit off in NIGHTLY differs from its default, so Settings offers Reset; an explicit on does not.
    @Test func resetFollowsTheBuildDefault() async throws {
        let descriptor = try #require(SettingsSchema.all.first { $0.path == UpdatesSettings.downloadAutomaticallyPath })
        for (json, customized) in [(#"{"updates": {"downloadAutomatically": false}}"#, true), (#"{"updates": {"downloadAutomatically": true}}"#, false)] {
            let (settings, home) = try await Self.settings(json, .channel(downloadsAutomatically: true))
            defer { try? FileManager.default.removeItem(at: home) }
            #expect(settings.defaultValue(of: descriptor) == .bool(true))
            #expect(settings.isCustomized(descriptor) == customized, "\(json)")
        }
    }

    @Test func stableStaysOptIn() async throws {
        let (settings, home) = try await Self.settings("{}", .channel(downloadsAutomatically: false))
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!settings.snapshot.updates.downloadAutomatically)
    }

    @Test func aValueSomeoneWroteWins() async throws {
        for (json, expected) in [(#"{"updates": {"downloadAutomatically": false}}"#, false), (#"{"updates": {"downloadAutomatically": "yes"}}"#, false)] {
            let (settings, home) = try await Self.settings(json, .channel(downloadsAutomatically: true))
            defer { try? FileManager.default.removeItem(at: home) }
            #expect(settings.snapshot.updates.downloadAutomatically == expected, "\(json) lost to the channel default")
        }
        let (settings, home) = try await Self.settings(#"{"updates": {"downloadAutomatically": true}}"#, .channel(downloadsAutomatically: false))
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(settings.snapshot.updates.downloadAutomatically, "an opt-in on stable was lost")
    }
}
