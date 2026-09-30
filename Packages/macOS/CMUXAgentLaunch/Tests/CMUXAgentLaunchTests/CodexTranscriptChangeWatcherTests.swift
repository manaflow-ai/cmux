import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("CodexTranscriptChangeWatcher")
struct CodexTranscriptChangeWatcherTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transcript-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // The monitor reads the transcript between arming and waiting. A write in
    // that window must wake the next wait instead of being lost until the
    // monitor's 30 second backstop.
    @Test("A write between arm and wait wakes the wait at once")
    func writeBeforeWaitIsReported() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let watcher = CodexTranscriptChangeWatcher()
        watcher.arm(paths: [transcript.path])
        try append("{\"checkpoint\":1}\n", to: transcript)

        let started = Date()
        #expect(watcher.wait(timeout: 30) == .changed)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("Writes during a read after a wake are reported by the following wait")
    func writeDuringReadAfterWakeIsReported() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let watcher = CodexTranscriptChangeWatcher()
        watcher.arm(paths: [transcript.path])
        try append("{\"row\":1}\n", to: transcript)
        #expect(watcher.wait(timeout: 30) == .changed)

        // The loop re-arms before its next read; the unchanged file keeps its
        // registration, so the write that lands during the read is not lost.
        watcher.arm(paths: [transcript.path])
        try append("{\"row\":2}\n", to: transcript)
        #expect(watcher.wait(timeout: 30) == .changed)
    }

    @Test("An unchanged file times out")
    func unchangedFileTimesOut() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let watcher = CodexTranscriptChangeWatcher()
        watcher.arm(paths: [transcript.path])
        #expect(watcher.wait(timeout: 0.05) == .timedOut)
    }

    @Test("A replaced transcript is watched on its new file")
    func replacedFileIsWatchedAgain() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let watcher = CodexTranscriptChangeWatcher()
        watcher.arm(paths: [transcript.path])
        let replacement = directory.appendingPathComponent("rollout.jsonl.new")
        try Data("{}\n".utf8).write(to: replacement)
        #expect(rename(replacement.path, transcript.path) == 0)
        #expect(watcher.wait(timeout: 30) == .changed)

        watcher.arm(paths: [transcript.path])
        try append("{\"row\":1}\n", to: transcript)
        #expect(watcher.wait(timeout: 30) == .changed)
    }

    @Test("A transcript created after the first arm is watched on the next arm")
    func lateTranscriptIsWatched() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")

        let watcher = CodexTranscriptChangeWatcher()
        watcher.arm(paths: [transcript.path])
        #expect(watcher.wait(timeout: 0.05) == .timedOut)

        try Data("{}\n".utf8).write(to: transcript)
        watcher.arm(paths: [transcript.path])
        try append("{\"row\":1}\n", to: transcript)
        #expect(watcher.wait(timeout: 30) == .changed)
    }

    @Test("Deleting the lease wakes the wait")
    func leaseDeletionIsReported() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        let lease = directory.appendingPathComponent("monitor.lease")
        try Data("{}\n".utf8).write(to: transcript)
        try Data("owner\n".utf8).write(to: lease)

        let watcher = CodexTranscriptChangeWatcher()
        watcher.arm(paths: [transcript.path, lease.path])
        try FileManager.default.removeItem(at: lease)
        #expect(watcher.wait(timeout: 30) == .changed)
    }

    @Test("A path dropped from arm no longer wakes the wait")
    func droppedPathIsUnwatched() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.jsonl")
        let current = directory.appendingPathComponent("current.jsonl")
        try Data("{}\n".utf8).write(to: old)
        try Data("{}\n".utf8).write(to: current)

        let watcher = CodexTranscriptChangeWatcher()
        watcher.arm(paths: [old.path])
        watcher.arm(paths: [current.path])
        try append("{\"row\":1}\n", to: old)
        #expect(watcher.wait(timeout: 0.05) == .timedOut)
    }
}
