import CmuxNextServerHelper
import Foundation
import Testing
@testable import CmuxNextApp

/// The app's record of applied fixes: empty when missing, unknown when
/// unreadable, private to the user (plans/cmux-next/server.md 9.4).
@Suite struct ServerFixLedgerTests {
    private func ledger() -> ServerFixLedger {
        ServerFixLedger(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fix-ledger-\(UUID().uuidString)/ledger.json"))
    }

    @Test func aMissingFileIsAnEmptyLedger() async {
        #expect(await ledger().load() == .fixes([]))
    }

    @Test func recordAndClearAreKeyedByFixAndPrivate() async throws {
        let ledger = ledger()
        try await ledger.record(.autoRestartOn)
        try await ledger.record(.systemSleepOffOnAC)
        try await ledger.record(.autoRestartOn)
        #expect(await ledger.load() == .fixes([.autoRestartOn, .systemSleepOffOnAC]))
        let attributes = try FileManager.default.attributesOfItem(atPath: ledger.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await ledger.clear(.autoRestartOn)
        #expect(await ledger.load() == .fixes([.systemSleepOffOnAC]))
        #expect(await ledger.load().toRevert == [.systemSleepOffOnAC])
    }

    @Test func anUnreadableOrForeignLedgerIsUnknownAndStaysUnknown() async throws {
        let ledger = ledger()
        try FileManager.default.createDirectory(at: ledger.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: ledger.url)
        #expect(await ledger.load() == .unknown)
        try await ledger.record(.autoRestartOn)
        #expect(await ledger.load() == .unknown, "a record never hides an unreadable ledger")
        #expect(ServerFixLedger.Contents.unknown.toRevert == ServerFix.allCases)

        try Data(#"{"version": 1, "fixes": {"pmset.future.fix": 1}}"#.utf8).write(to: ledger.url)
        #expect(await ledger.load() == .unknown, "a fix id this build does not know fails safe")
        try await ledger.reset()
        #expect(await ledger.load() == .fixes([]))
    }
}
