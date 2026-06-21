import Foundation
import Testing
@testable import CmuxSettings

/// Behavior of the `session.*` settings through the real JSON store: the
/// defaults users get out of the box (restore = ask, per-tab shell history
/// on), hand-edited values, unknown fallbacks, and the synchronous
/// ``JSONConfigStore/snapshotValue(for:)`` read used at launch and spawn time.
@Suite("session.*")
struct SessionSettingsTests {
    private func makeStore() -> (JSONConfigStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        return (JSONConfigStore(fileURL: fileURL), fileURL)
    }

    @Test func restoreModeDefaultsToAsk() async {
        #expect(SettingCatalog().session.restoreMode.defaultValue == .ask)
        let (store, _) = makeStore()
        let value = await store.value(for: SettingCatalog().session.restoreMode)
        #expect(value == .ask)
    }

    @Test func persistShellHistoryDefaultsToTrue() async {
        #expect(SettingCatalog().session.persistShellHistory.defaultValue == true)
        let (store, _) = makeStore()
        let value = await store.value(for: SettingCatalog().session.persistShellHistory)
        #expect(value == true)
    }

    @Test func readsEachRestoreModeFromHandEditedConfigFile() async throws {
        for raw in ["always", "ask", "never"] {
            let (store, fileURL) = makeStore()
            try "{ \"session\": { \"restoreMode\": \"\(raw)\" } }"
                .write(to: fileURL, atomically: true, encoding: .utf8)
            let value = await store.value(for: SettingCatalog().session.restoreMode)
            #expect(value == SessionRestoreMode(rawValue: raw))
        }
    }

    @Test func unknownRestoreModeFallsBackToAsk() async throws {
        let (store, fileURL) = makeStore()
        try #"{ "session": { "restoreMode": "yolo" } }"#
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let value = await store.value(for: SettingCatalog().session.restoreMode)
        #expect(value == .ask)
    }

    @Test func persistShellHistoryReadsFalseFromConfigFile() async throws {
        let (store, fileURL) = makeStore()
        try #"{ "session": { "persistShellHistory": false } }"#
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let value = await store.value(for: SettingCatalog().session.persistShellHistory)
        #expect(value == false)
    }

    @Test func roundTripsRestoreModeThroughTheStore() async throws {
        let (store, fileURL) = makeStore()
        try await store.set(.never, for: SettingCatalog().session.restoreMode)
        let value = await store.value(for: SettingCatalog().session.restoreMode)
        #expect(value == .never)

        // The on-disk representation is the raw string, hand-editable.
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let section = parsed?["session"] as? [String: Any]
        #expect(section?["restoreMode"] as? String == "never")
    }

    /// The launch/spawn paths read these keys synchronously off the main
    /// actor via ``JSONConfigStore/snapshotValue(for:)``; confirm it observes
    /// hand-edited values and the defaults.
    @Test func snapshotValueReadsSynchronously() async throws {
        let (store, fileURL) = makeStore()
        #expect(store.snapshotValue(for: SettingCatalog().session.restoreMode) == .ask)
        #expect(store.snapshotValue(for: SettingCatalog().session.persistShellHistory) == true)

        try #"{ "session": { "restoreMode": "never", "persistShellHistory": false } }"#
            .write(to: fileURL, atomically: true, encoding: .utf8)
        #expect(store.snapshotValue(for: SettingCatalog().session.restoreMode) == .never)
        #expect(store.snapshotValue(for: SettingCatalog().session.persistShellHistory) == false)
    }
}
