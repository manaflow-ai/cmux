import CmuxNextWakeups
import Foundation
import Testing

/// ``MainDirectoryWatch`` is the one adapter for the socket clients' directory sources
/// (AgentActivitySocketSource, AgentTurnStateFeed, SocketTasksSource): a change in the directory
/// runs the main-actor handler on the main thread, and a released watch runs nothing (the clients'
/// deinits used to cancel their raw sources only when released on the main thread).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MainDirectoryWatchTests {
    /// Main-actor counts the handlers write (a class, so the `@Sendable` handlers can share it).
    final class Seen {
        var runs = 0
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func aChangeInTheDirectoryRunsTheHandlerOnTheMainThread() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (events, event) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(8))
        let watch = try #require(MainDirectoryWatch(directory.path) { event.yield(Thread.isMainThread) })
        FileManager.default.createFile(atPath: directory.appendingPathComponent("tasks.sock").path, contents: nil)
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == true, "the handler runs on the main thread")
        withExtendedLifetime(watch) {}
    }

    @Test func aReleasedWatchRunsNothing() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let released = Seen()
        var gone: MainDirectoryWatch? = MainDirectoryWatch(directory.path) { released.runs += 1 }
        #expect(gone != nil)
        gone = nil
        // A second watch on the same directory sees the same change: once it ran, the released
        // one would have run too.
        let (events, event) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(8))
        let kept = try #require(MainDirectoryWatch(directory.path) { event.yield() })
        FileManager.default.createFile(atPath: directory.appendingPathComponent("tasks.sock").path, contents: nil)
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(released.runs == 0)
        withExtendedLifetime(kept) {}
    }

    @Test func aMissingDirectoryGivesNoWatch() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)").path
        #expect(MainDirectoryWatch(missing, {}) == nil)
    }
}
