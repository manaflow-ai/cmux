import Foundation
import Testing
@testable import CmuxSettings

/// Behavior of the `updates.channel` setting through the real JSON store: the
/// on-disk strings users put in `~/.config/cmux/cmux.json` must decode to the
/// right channel, and anything else must fall back to the stable default.
@Suite("updates.channel")
struct UpdateChannelSettingTests {
    private func makeStore() -> (JSONConfigStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-update-channel-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        return (JSONConfigStore(fileURL: fileURL), fileURL)
    }

    @Test func defaultsToStableWhenUnset() async {
        let (store, _) = makeStore()
        let value = await store.value(for: SettingCatalog().updates.channel)
        #expect(value == .stable)
    }

    @Test func readsRCFromHandEditedConfigFile() async throws {
        let (store, fileURL) = makeStore()
        try #"{ "updates": { "channel": "rc" } }"#
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let value = await store.value(for: SettingCatalog().updates.channel)
        #expect(value == .rc)
    }

    @Test func unknownRawValueFallsBackToStable() async throws {
        let (store, fileURL) = makeStore()
        try #"{ "updates": { "channel": "nightly" } }"#
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let value = await store.value(for: SettingCatalog().updates.channel)
        #expect(value == .stable)
    }

    @Test func roundTripsThroughTheStore() async throws {
        let (store, fileURL) = makeStore()
        try await store.set(.rc, for: SettingCatalog().updates.channel)
        #expect(await store.value(for: SettingCatalog().updates.channel) == .rc)
        #expect(store.snapshotValue(for: SettingCatalog().updates.channel) == .rc)

        // The on-disk representation is the raw string, hand-editable.
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let section = parsed?["updates"] as? [String: Any]
        #expect(section?["channel"] as? String == "rc")

        try await store.set(.stable, for: SettingCatalog().updates.channel)
        #expect(await store.value(for: SettingCatalog().updates.channel) == .stable)
    }

    @Test func catalogListsTheKey() {
        #expect(SettingCatalog().all.contains { $0.id == "updates.channel" })
    }
}
