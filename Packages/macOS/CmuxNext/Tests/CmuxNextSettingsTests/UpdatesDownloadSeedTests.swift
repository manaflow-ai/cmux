@testable import CmuxNextSettings
import CmuxNextActions
import CmuxNextDesign
import Foundation
import Testing

/// `updates.downloadAutomatically` is opt-in on stable; the dogfood apps (NIGHTLY, DEV) write their
/// default while it is unset, at launch and after Reset, and never over a value someone wrote.
@MainActor @Suite(.serialized) struct UpdatesDownloadSeedTests {
    private static func settings(_ json: String) async throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-download-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, home)
    }

    @Test func anUnsetKeyIsSeededOnlyWhereTheChannelDownloads() async throws {
        let (settings, home) = try await Self.settings("{}")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try await !settings.seedDownloadAutomatically(channelDefault: false), "stable wrote an opt-in")
        #expect(try await settings.file.value(at: UpdatesSettings.downloadAutomaticallyPath) == nil)
        #expect(try await settings.seedDownloadAutomatically(channelDefault: true))
        #expect(try await settings.file.value(at: UpdatesSettings.downloadAutomaticallyPath) == .bool(true))
    }

    @Test func aValueSomeoneWroteStays() async throws {
        let (settings, home) = try await Self.settings(#"{"updates": {"downloadAutomatically": false}}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try await !settings.seedDownloadAutomatically(channelDefault: true))
        #expect(try await settings.file.value(at: UpdatesSettings.downloadAutomaticallyPath) == .bool(false))
    }

    /// The person's write that lands between the snapshot read and the seed wins.
    @Test func theSeedNeverOverwritesAWriteThatLandedFirst() async throws {
        let (settings, home) = try await Self.settings("{}")
        defer { try? FileManager.default.removeItem(at: home) }
        try await settings.file.set(.bool(false), at: UpdatesSettings.downloadAutomaticallyPath)
        #expect(try await !settings.file.setIfAbsent(.bool(true), at: UpdatesSettings.downloadAutomaticallyPath))
        #expect(try await settings.file.value(at: UpdatesSettings.downloadAutomaticallyPath) == .bool(false))
    }
}
