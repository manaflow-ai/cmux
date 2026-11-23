@testable import CmuxNextSettings
import CmuxNextActions
import CmuxNextDesign
import Foundation
import Testing

/// Automatic Updates (`updates.automatic`) is Notify Only on stable and Download Automatically by default in
/// NIGHTLY and DEV. The channel default fills the effective settings only: cmux-next.json is shared by every
/// channel, so nothing is written there, and a value someone wrote always wins, including one of the toggles
/// the choice replaced (retired-keys.json).
@MainActor @Suite(.serialized) struct SettingsBuildDefaultsTests {
    private static func settings(_ json: String, _ defaults: SettingsBuildDefaults) async throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-build-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [],
                                          buildDefaults: defaults)
        await settings.reload()
        return (settings, home)
    }

    @Test func theDogfoodDefaultFillsTheEffectiveSettingsOnly() async throws {
        let (settings, home) = try await Self.settings("{}", .channel(downloadsAutomatically: true))
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(settings.snapshot.updates.automatic == .download, "NIGHTLY and DEV download by default")
        #expect(settings.snapshot.updates.downloadAutomatically)
        #expect(settings.fileRoot.value(at: UpdatesSettings.automaticPath) == nil, "the channel default counted as the person's")
        #expect(try await settings.file.value(at: UpdatesSettings.automaticPath) == nil, "the channel default was written to the shared file")
    }

    /// A pick other than Download Automatically in NIGHTLY differs from its default, so Settings offers Reset.
    @Test func resetFollowsTheBuildDefault() async throws {
        let descriptor = try #require(SettingsSchema.all.first { $0.path == UpdatesSettings.automaticPath })
        for (json, customized) in [(#"{"updates": {"automatic": "notify"}}"#, true), (#"{"updates": {"automatic": "download"}}"#, false)] {
            let (settings, home) = try await Self.settings(json, .channel(downloadsAutomatically: true))
            defer { try? FileManager.default.removeItem(at: home) }
            #expect(settings.defaultValue(of: descriptor) == .string("download"))
            #expect(settings.isCustomized(descriptor) == customized, "\(json)")
        }
    }

    @Test func stableStaysOptIn() async throws {
        let (settings, home) = try await Self.settings("{}", .channel(downloadsAutomatically: false))
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(settings.snapshot.updates.automatic == .notify)
        #expect(!settings.snapshot.updates.downloadAutomatically)
    }

    @Test func aValueSomeoneWroteWins() async throws {
        for (json, expected) in [
            (#"{"updates": {"automatic": "notify"}}"#, UpdatesAutomaticSetting.notify),
            (#"{"updates": {"automatic": "off"}}"#, .off),
            (#"{"updates": {"downloadAutomatically": false}}"#, .notify),
            (#"{"updates": {"checkAutomatically": false}}"#, .off),
            (#"{"updates": {"installWhenIdle": true}}"#, .idle),
        ] {
            let (settings, home) = try await Self.settings(json, .channel(downloadsAutomatically: true))
            defer { try? FileManager.default.removeItem(at: home) }
            #expect(settings.snapshot.updates.automatic == expected, "\(json) lost to the channel default")
        }
        for json in [#"{"updates": {"automatic": "download"}}"#, #"{"updates": {"downloadAutomatically": true}}"#] {
            let (settings, home) = try await Self.settings(json, .channel(downloadsAutomatically: false))
            defer { try? FileManager.default.removeItem(at: home) }
            #expect(settings.snapshot.updates.automatic == .download, "an opt-in on stable was lost: \(json)")
        }
    }

    /// A profile or team policy that still forces an old update toggle forces and locks the choice
    /// (greptile on cmux#51125), and the readers ask for the old names.
    @Test func aForcedOldToggleForcesAndLocksTheChoice() {
        let file: JSONValue = .object(["updates": .object(["automatic": .string("download")])])
        let merged = EffectiveSettings.merge(file: file, managed: ManagedPreferences(forced: ["updates.checkAutomatically": .bool(false)]),
                                             team: .none)
        #expect(merged.root.value(at: UpdatesSettings.automaticPath) == .string("off"))
        #expect(merged.managedKeys["updates.automatic"] == .device)
        let team = EffectiveSettings.merge(file: .object([:]), managed: ManagedPreferences(),
                                           team: TeamPolicyLayer(teamName: "T", enforced: ["updates.downloadAutomatically": .bool(false)]))
        #expect(team.root.value(at: UpdatesSettings.automaticPath) == .string("notify"))
        #expect(team.managedKeys["updates.automatic"] == .team("T"))
        #expect(CFManagedPreferenceReader.readKeys.contains("updates.checkAutomatically"))
    }
}
