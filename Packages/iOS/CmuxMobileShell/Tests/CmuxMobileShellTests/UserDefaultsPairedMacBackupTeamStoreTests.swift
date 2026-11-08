import Foundation
import Testing
@testable import CmuxMobileShell

/// The persisted backup-team mapping must stay BOUNDED. Mappings retire only
/// when THIS device delivers the pairing's tombstone; records deleted from
/// another device, abandoned accounts, and expired server records would
/// otherwise accumulate forever — and every route mirror deserializes and
/// rewrites the whole dictionary, so storage and per-update work grow without
/// bound.
@Suite struct UserDefaultsPairedMacBackupTeamStoreTests {
    @Test func mappingRetentionIsBounded() async throws {
        let suite = "test.backupTeams.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPairedMacBackupTeamStore(defaults: UserDefaults(suiteName: suite)!)

        for index in 0..<600 {
            await store.save("team-\(index % 7)", key: "user-1\u{0}\u{0}mac-\(index)")
        }

        let persisted = UserDefaults(suiteName: suite)!
            .dictionary(forKey: "cmux.mobile.pairedMacBackup.backupTeams.v1")
        let count = (persisted ?? [:]).count
        #expect(count <= 512)
        // The most recently saved mappings are the ones a live forget still
        // needs; eviction must drop the oldest, not the newest.
        #expect(await store.load(key: "user-1\u{0}\u{0}mac-599") == "team-\(599 % 7)")
    }
}
