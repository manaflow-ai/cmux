@testable import CmuxNextSettings
import Foundation
import Testing

/// The watcher reports a change within a second of the save, measured on the
/// watcher's own queue, so main-actor load in the full package run does not
/// enter the bound. (`ManagedPreferencesTests` covers the reload wiring; its
/// duration includes main-actor hops and is not a watcher latency.)
@Suite struct ConfigFileWatcherTests {
    static let bound: Duration = .seconds(1)

    /// Records the instant of every `onChange` call on the watcher queue.
    final class Events: Sendable {
        let stream: AsyncStream<ContinuousClock.Instant>
        let continuation: AsyncStream<ContinuousClock.Instant>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream(of: ContinuousClock.Instant.self)
        }

        func record() { continuation.yield(.now) }

        /// The first event at or after `instant`, or nil after `timeout`.
        func first(after instant: ContinuousClock.Instant, timeout: Duration = .seconds(10)) async -> ContinuousClock.Instant? {
            let stream = stream
            return await withTaskGroup(of: ContinuousClock.Instant?.self) { group in
                group.addTask {
                    for await event in stream where event >= instant { return event }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
        }
    }

    func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func expectPrompt(_ event: ContinuousClock.Instant?, after saved: ContinuousClock.Instant, _ what: String,
                      sourceLocation: SourceLocation = #_sourceLocation) {
        guard let event else {
            Issue.record("\(what): no change reported within 10 s", sourceLocation: sourceLocation)
            return
        }
        #expect(event - saved < Self.bound, "\(what): reported after \(event - saved)", sourceLocation: sourceLocation)
    }

    @Test func aFileSavedInADirectoryThatDidNotExistIsReportedAtOnce() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "profiles").appending(path: "com.manaflow.cmux.plist")
        let events = Events()
        let watcher = ConfigFileWatcher(url: file) { events.record() }
        let armed = ContinuousClock.now
        watcher.start()
        defer { watcher.stop() }
        // start() reports once after arming; the save comes after that.
        _ = try #require(await events.first(after: armed), "start() reports once")

        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = ContinuousClock.now
        try Data("<plist/>".utf8).write(to: file, options: .atomic)
        expectPrompt(await events.first(after: saved), after: saved, "first save into a new directory")
    }

    @Test func everyAtomicReplaceIsReportedAtOnce() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: file)
        let events = Events()
        let watcher = ConfigFileWatcher(url: file) { events.record() }
        let armed = ContinuousClock.now
        watcher.start()
        defer { watcher.stop() }
        _ = try #require(await events.first(after: armed), "start() reports once")

        // The second replace proves the watch re-armed on the new inode.
        for round in 1...2 {
            let saved = ContinuousClock.now
            try Data("{\"round\": \(round)}".utf8).write(to: file, options: .atomic)
            expectPrompt(await events.first(after: saved), after: saved, "atomic replace \(round)")
        }
    }
}
