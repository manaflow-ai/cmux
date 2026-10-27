@testable import CmuxNextApp
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// p14-energy-127: before acpmux's socket exists, the chats feed watches the socket's folder, which other
/// processes write. With `hiddenWatcherPause` a burst of their writes is one look for the socket after one
/// flexible deadline (250 ms, 1 s in Energy Saver), never one main-thread task per write. The chats themselves
/// stay a live push.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ChatsFeedSocketFolderTests {
    /// A new folder for a socket that does not exist yet.
    private static func socketFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("chats-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func energySaverStretchesTheSocketFolderWaitFourTimes() {
        let wait = ChatsFeed.coalescedSocketFolderWait
        #expect(ChatsFeed.socketFolderWait(wait, in: .normal) == .milliseconds(250))
        #expect(ChatsFeed.socketFolderWait(wait, in: EnergyPolicy(saverReason: .lowPowerMode)) == .seconds(1))
        #expect(ChatsFeed.socketFolderWait(.zero, in: EnergyPolicy(saverReason: .lowPowerMode)) == .zero)
    }

    /// Writes 50 files into `folder` (another process's burst) and returns the deadlines it asked of `clock`
    /// once the first of them is asleep on it.
    private static func burst(in folder: URL, clock: ManualClock) async throws -> [ManualClock.SleepRequest] {
        for index in 0..<50 {
            try Data("\(index)".utf8).write(to: folder.appendingPathComponent("log-\(index).txt"))
        }
        try await clock.waitForSleeper()
        return clock.sleepRequests
    }

    @Test func aBurstOfWritesInTheSocketFolderIsOneLookForTheSocket() async throws {
        let folder = try Self.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ManualClock()
        let feed = ChatsFeed(socketPath: folder.appendingPathComponent("acpmux.sock").path,
                             deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())),
                             socketFolderWait: ChatsFeed.coalescedSocketFolderWait, clock: clock)
        let (looks, looked) = AsyncStream.makeStream(of: Void.self)
        feed.lookedForSocket = { looked.yield() }
        // No socket yet: the feed watches its folder.
        feed.keepCurrent()
        // However many of the 50 notices arrived, the burst asked for one deadline and looked for nothing yet.
        let requests = try await Self.burst(in: folder, clock: clock)
        #expect(requests.map(\.deadline.offset) == [.milliseconds(250)])
        #expect(requests.map(\.tolerance) == [.milliseconds(25)])
        clock.advance(by: .milliseconds(250))
        var iterator = looks.makeAsyncIterator()
        #expect(await iterator.next() != nil, "the burst's deadline did not look for the socket")
        withExtendedLifetime(feed) {}
    }

    /// Without the feature (no wait) a notice looks for the socket at once and asks the clock for nothing.
    @Test func withNoWaitANoticeLooksAtOnce() async throws {
        let folder = try Self.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ManualClock()
        let feed = ChatsFeed(socketPath: folder.appendingPathComponent("acpmux.sock").path,
                             deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())), clock: clock)
        let (looks, looked) = AsyncStream.makeStream(of: Void.self)
        feed.lookedForSocket = { looked.yield() }
        feed.keepCurrent()
        try Data("x".utf8).write(to: folder.appendingPathComponent("log.txt"))
        var iterator = looks.makeAsyncIterator()
        #expect(await iterator.next() != nil, "the notice did not look for the socket")
        #expect(clock.sleepRequests.isEmpty)
        withExtendedLifetime(feed) {}
    }

    @Test func energySaverWaitsFourTimesLongerBeforeTheLook() async throws {
        let folder = try Self.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ManualClock()
        let work = MainWorkScheduler(budget: MainFrameBudget())
        work.energy.update(EnergyPolicy(saverReason: .setting))
        let feed = ChatsFeed(socketPath: folder.appendingPathComponent("acpmux.sock").path,
                             deadlines: MainDeadlineScheduler(work: work),
                             socketFolderWait: ChatsFeed.coalescedSocketFolderWait, clock: clock)
        feed.keepCurrent()
        let requests = try await Self.burst(in: folder, clock: clock)
        #expect(requests.map(\.deadline.offset) == [.seconds(1)])
        #expect(requests.map(\.tolerance) == [.milliseconds(100)])
        withExtendedLifetime(feed) {}
    }
}
