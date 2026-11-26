import Foundation
import Testing
@testable import CmuxTerminalCore

/// Exercises the production change source against real temporary files, with
/// the save patterns editors use for config files.
@Suite(.timeLimit(.minutes(1))) struct FileWatcherGhosttyConfigChangeSourceTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-config-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Awaits the next change, bounded so a broken watcher fails instead of
    /// hanging CI.
    private func nextChange(
        _ subscription: GhosttyConfigChangeSubscription,
        within seconds: Double = 5
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = subscription.events.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    @Test func moveAsideAndRewriteSaveKeepsReportingChanges() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        try "font-size = 13\n".write(to: config, atomically: false, encoding: .utf8)

        let subscription = await FileWatcherGhosttyConfigChangeSource()
            .subscribe(toPaths: [config.path])

        // Vim's default save: rename the original to a backup, write a new file.
        let backup = directory.appendingPathComponent("config~")
        try FileManager.default.moveItem(at: config, to: backup)
        try "font-size = 14\n".write(to: config, atomically: false, encoding: .utf8)
        #expect(await nextChange(subscription))

        // Smoke check that the subscription is still live after the save. The
        // stream keeps the newest undelivered event, so this can also be
        // satisfied by a late event from the save burst; FileWatcherTests
        // covers the inode reattachment itself.
        try "font-size = 15\n".write(to: config, atomically: false, encoding: .utf8)
        #expect(await nextChange(subscription))

        await subscription.cancel()
    }

    @Test func includeCreatedAfterSubscribingReportsChange() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let include = directory.appendingPathComponent("nested/colors.conf")

        let subscription = await FileWatcherGhosttyConfigChangeSource()
            .subscribe(toPaths: [include.path])

        try FileManager.default.createDirectory(
            at: include.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "background = #000000\n".write(to: include, atomically: true, encoding: .utf8)
        #expect(await nextChange(subscription))

        await subscription.cancel()
    }

    @Test func cancelFinishesEvents() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subscription = await FileWatcherGhosttyConfigChangeSource()
            .subscribe(toPaths: [directory.appendingPathComponent("config").path])
        var iterator = subscription.events.makeAsyncIterator()

        await subscription.cancel()

        let next: Void? = await iterator.next()
        #expect(next == nil)
    }
}
