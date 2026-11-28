@testable import CmuxNextSettings
import CmuxNextActions
import CmuxNextDesign
import Foundation
import Testing

/// Automatic Updates (`updates.automatic`) is Download Automatically by default on every channel (Leo
/// 2026-11-07). The channel default fills the effective settings only: cmux-next.json is shared by every
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

    /// Automatic download is the schema's default (Leo 2026-11-07: "Yeah, let's do that, man"), so a
    /// build with no channel default downloads by itself too.
    @Test func theSchemaDefaultDownloadsAutomatically() async throws {
        let (settings, home) = try await Self.settings("{}", .channel(downloadsAutomatically: false))
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(settings.snapshot.updates.automatic == .download)
        #expect(settings.snapshot.updates.downloadAutomatically)
    }

    /// A value someone wrote is never filled by the build default; one that does not decode reads as
    /// the schema's default.
    @Test func aValueSomeoneWroteWins() async throws {
        for (json, expected) in [
            (#"{"updates": {"automatic": "notify"}}"#, UpdatesAutomaticSetting.notify),
            (#"{"updates": {"automatic": "off"}}"#, .off),
            (#"{"updates": {"downloadAutomatically": false}}"#, .notify),
            (#"{"updates": {"downloadAutomatically": "yes"}}"#, .download),
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

    /// Install When Idle is the Automatic Updates default in cmux NEXT NIGHTLY and not in release (Leo, 2026-11-22:
    /// "auto be de facto able to click the restart button"); an explicit pick in NIGHTLY wins and the default is
    /// never written for him.
    @Test func updateWhenIdleFollowsTheBuild() async throws {
        let nightly = SettingsBuildDefaults.channel(downloadsAutomatically: true, installsWhenIdle: true)
        do {
            let (settings, home) = try await Self.settings("{}", nightly)
            defer { try? FileManager.default.removeItem(at: home) }
            #expect(settings.snapshot.updates.installWhenIdle, "NIGHTLY restarts when away by default")
            #expect(try await settings.file.value(at: UpdatesSettings.automaticPath) == nil, "the build default was written")
        }
        do {
            let (settings, home) = try await Self.settings(#"{"updates": {"automatic": "download"}}"#, nightly)
            defer { try? FileManager.default.removeItem(at: home) }
            #expect(!settings.snapshot.updates.installWhenIdle, "an explicit Download Automatically lost to the build default")
        }
        let (settings, home) = try await Self.settings("{}", .channel(downloadsAutomatically: false))
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!settings.snapshot.updates.installWhenIdle, "release stays off")
    }
}
