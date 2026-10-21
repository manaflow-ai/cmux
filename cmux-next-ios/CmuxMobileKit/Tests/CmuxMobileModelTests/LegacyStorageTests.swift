import Foundation
import Testing
@testable import CmuxMobileModel

/// An update from a pre-rename build (1.2.0, when the app was called cnx) keeps its
/// settings, account, team and Chief outboxes.
@Suite struct LegacyStorageTests {
    @Test func preRenameSettingsMoveToTheNewKeys() throws {
        let suite = "LegacyStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(15, forKey: "cnx.settings.terminalFontSize")
        defaults.set("team-1", forKey: "cnx.lastTeamID")
        defaults.set(true, forKey: "cnx.setupComplete")
        defaults.set("mac-1", forKey: "cnx.live.mac.team-1")
        // A value the new build already wrote wins over the old one.
        defaults.set("team-2", forKey: "cmuxMobile.auth.selectedTeam")
        defaults.set("team-old", forKey: "cnx.auth.selectedTeam")
        defaults.set("kept", forKey: "unrelated.key")

        let moved = LegacyStorage.migrateDefaults(defaults)

        #expect(moved == ["cnx.auth.selectedTeam", "cnx.lastTeamID", "cnx.live.mac.team-1",
                          "cnx.settings.terminalFontSize", "cnx.setupComplete"])
        #expect(defaults.integer(forKey: "cmuxMobile.settings.terminalFontSize") == 15)
        #expect(defaults.string(forKey: "cmuxMobile.lastTeamID") == "team-1")
        #expect(defaults.bool(forKey: "cmuxMobile.setupComplete"))
        #expect(defaults.string(forKey: "cmuxMobile.live.mac.team-1") == "mac-1")
        #expect(defaults.string(forKey: "cmuxMobile.auth.selectedTeam") == "team-2")
        #expect(defaults.object(forKey: "cnx.lastTeamID") == nil)
        #expect(defaults.string(forKey: "unrelated.key") == "kept")
        // Idempotent.
        #expect(LegacyStorage.migrateDefaults(defaults).isEmpty)
    }

    /// A signed-out account's record keeps its preferences under their own keys; they move
    /// too, so that account signing in again skips setup and finds its Mac.
    @Test func aSignedOutAccountsRecordMovesWithItsKeys() throws {
        let suite = "LegacyStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("", forKey: "cnx.account.current")
        defaults.set(["cnx.setupComplete": true, "cnx.live.mac.team-1": "mac-1"], forKey: "cnx.account.user-a")

        LegacyStorage.migrateDefaults(defaults)

        #expect(defaults.string(forKey: "cmuxMobile.account.current") == "")
        let prefs = AccountPreferences(defaults: defaults)
        #expect(prefs.value("cmuxMobile.setupComplete", userID: "user-a") as? Bool == true)
        prefs.activate(userID: "user-a")
        #expect(defaults.bool(forKey: "cmuxMobile.setupComplete"))
        #expect(defaults.string(forKey: "cmuxMobile.live.mac.team-1") == "mac-1")
    }

    @Test func preRenameOutboxesAndSnapshotsAreRenamed() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "LegacyStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data("[1]".utf8).write(to: dir.appending(path: "cnx-chief-outbox.json"))
        try fm.createDirectory(at: dir.appending(path: "cnx-live"), withIntermediateDirectories: true)
        try Data("s".utf8).write(to: dir.appending(path: "cnx-live/snapshot.json"))
        // The new build already has a cloud outbox: the old one is left alone, never merged over it.
        try Data("[old]".utf8).write(to: dir.appending(path: "cnx-cloud-chief-outbox.json"))
        try Data("[new]".utf8).write(to: dir.appending(path: "cmux-mobile-cloud-chief-outbox.json"))

        LegacyStorage.migrateFiles(in: dir)

        #expect(try Data(contentsOf: dir.appending(path: "cmux-mobile-chief-outbox.json")) == Data("[1]".utf8))
        #expect(try Data(contentsOf: dir.appending(path: "cmux-mobile-live/snapshot.json")) == Data("s".utf8))
        #expect(try Data(contentsOf: dir.appending(path: "cmux-mobile-cloud-chief-outbox.json")) == Data("[new]".utf8))
        #expect(!fm.fileExists(atPath: dir.appending(path: "cnx-chief-outbox.json").path))
    }
}
