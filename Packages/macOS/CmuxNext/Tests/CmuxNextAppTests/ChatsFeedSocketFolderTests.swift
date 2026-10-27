@testable import CmuxNextApp
import CmuxNextWakeups
import Foundation
import Testing

/// p14-energy-127: before acpmux's socket exists, the chats feed watches the socket's folder, which other
/// processes write. A burst of their writes is one look for the socket after a flexible wait (250 ms, 1 s in
/// Energy Saver), never one main-thread task per write. The chats themselves stay a live push.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ChatsFeedSocketFolderTests {
    private static let owner = "ChatsFeed.socketFolder"

    /// The fires of the feed's socket-folder timer so far (the shared ledger, where every DemandTimer of the
    /// app records; only this feed uses the owner).
    private static func fires() -> UInt64 {
        WakeupLedger.shared.snapshot().first { $0.owner == owner && $0.reason == "deadline" }?.count ?? 0
    }

    @Test func energySaverStretchesTheSocketFolderWaitFourTimes() {
        #expect(ChatsFeed.socketFolderWait(in: .normal) == .milliseconds(250))
        #expect(ChatsFeed.socketFolderWait(in: EnergyPolicy(saverReason: .lowPowerMode)) == .seconds(1))
    }

    @Test func aBurstOfWritesInTheSocketFolderIsOneLookForTheSocket() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("chats-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = ChatsFeed(socketPath: folder.appendingPathComponent("acpmux.sock").path,
                             deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())))
        // No socket yet: the feed watches its folder.
        feed.keepCurrent()
        let before = Self.fires()
        for index in 0..<50 {
            try Data("\(index)".utf8).write(to: folder.appendingPathComponent("log-\(index).txt"))
        }
        // wakeup-allow: fixture bounded wait (5 s) for the coalesced fire on the wall clock
        for _ in 0..<500 where Self.fires() == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(Self.fires() == before + 1, "the burst did not fire the socket-folder timer")
        // Longer than the wait again: the 50 writes made no second fire.
        try await Task.sleep(for: .milliseconds(600))
        #expect(Self.fires() == before + 1, "a burst of 50 writes looked for the socket more than once")
        withExtendedLifetime(feed) {}
    }
}
