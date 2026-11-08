@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Chief chat's teleport row is an event, not a standing state (user, Nov 7: "keep seeing this on
/// this page"): "Chief forked to cmux Cloud as …" and "Chief moved to …" show once, when the app sees the
/// fork or move happen, and never again after a reload or a relaunch. Before, the row was drawn from
/// `fork.json` / `moved.json` on every read, so it sat under the newest message for good.
@MainActor
struct ChiefTeleportAnnouncementTests {
    private static func fork(_ chief: String) -> Data {
        Data(#"{"api": "https://api.cmux.dev", "chief": "\#(chief)", "conversation": "conv_1", "name": "Chief fork", "at": "2026-11-06T08:34:00Z", "memory_messages": 1, "history_imported": 1}"#.utf8)
    }
    private static let moved = Data(#"{"to": "cloud:https://api.cmux.dev/agent_9", "at": "2026-11-06T16:02:11Z", "checkpoint_sha256": "ab"}"#.utf8)

    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("chief-teleport-once-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("state"), withIntermediateDirectories: true)
        return home
    }

    private func teleportModel(_ home: URL) async -> ChiefTeleportModel {
        let chief = ChiefTeleportModel(home: home, reader: ChiefLocationReader(isRunning: { _ in false }))
        await chief.refresh().value
        return chief
    }

    @Test func aForkMadeBeforeLaunchShowsNoRow() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.fork("agent_fork").write(to: home.appendingPathComponent("state/fork.json"))
        let chief = await teleportModel(home)
        #expect(chief.marks.fork?.chief == "agent_fork", "the chip and menu still know the fork")
        #expect(chief.notice() == nil, "an old fork is not news: no row at launch")
        // A reload reads the same marks again: still no row.
        await chief.refresh().value
        #expect(chief.notice() == nil)
    }

    @Test func aMoveMadeBeforeLaunchShowsNoRow() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.moved.write(to: home.appendingPathComponent("state/moved.json"))
        let chief = await teleportModel(home)
        #expect(chief.location == .cloud, "the chip still says where the Chief is")
        #expect(chief.notice() == nil)
    }

    @Test func aForkSeenHappeningShowsOnceAndNotAfterARelaunch() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let chief = await teleportModel(home)
        #expect(chief.notice() == nil)
        try Self.fork("agent_fork").write(to: home.appendingPathComponent("state/fork.json"))
        await chief.refresh().value
        let row = try #require(chief.notice())
        #expect(row.hasPrefix("Chief forked to cmux Cloud as “Chief fork”"))
        // The app starts again (a relaunch) on the same home: the fork is old news.
        let relaunched = await self.teleportModel(home)
        #expect(relaunched.notice() == nil)
    }
}
