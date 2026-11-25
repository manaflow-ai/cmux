import CmuxNextSettings
import Foundation
import Testing

/// The nightly theme-live-reload flow saves a theme file ten times by atomic replace (write a temp
/// file beside it, rename over it). Every save must reach `onChange`, not just the first nine
/// (manaflow-ai/cmux#55689). Leo: "you guys needed to test the flows as well to know there was
/// actually a path to do anything".
struct ConfigFileWatcherAtomicSaveTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "cmux-watch-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "themes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func atomicRename(_ text: String, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp")
        try text.write(to: temp, atomically: false, encoding: .utf8)
        #expect(rename(temp.path, url.path) == 0)
    }

    /// Saves `count` times, `spacing` apart; each save must produce a notification within five seconds.
    private func run(count: Int, spacing: Duration) async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let file = folder.appending(path: "probe.json")
        try "0".write(to: file, atomically: true, encoding: .utf8)
        let counter = Counter()
        let watcher = ConfigFileWatcher(url: file) { counter.bump() }
        watcher.start(reportInitialChange: false)
        defer { watcher.stop() }
        for save in 1...count {
            let before = counter.count
            try Self.atomicRename("\(save)", to: file)
            var waited = 0
            while counter.count == before, waited < 5_000 {
                try await Task.sleep(for: .milliseconds(10))
                waited += 10
            }
            #expect(counter.count > before, "save \(save) of \(count) was never reported")
            if counter.count == before { return }
            try await Task.sleep(for: spacing)
        }
    }

    @Test func fiftyRapidAtomicRenamesAreEachReported() async throws {
        try await run(count: 50, spacing: .milliseconds(100))
    }

    @Test func twelveAtomicRenamesAtTheProbesPaceAreEachReported() async throws {
        try await run(count: 12, spacing: .milliseconds(1_700))
    }
}
