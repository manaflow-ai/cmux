import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import CmuxNextApp

/// A writer the test holds shut until it opens the gate, recording the
/// thread of each write.
nonisolated final class RunMarkerGatedWriter: Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let entered = DispatchSemaphore(value: 0)
    private let log = Mutex<[(main: Bool, data: Data)]>([])

    func write(_ data: Data, _ url: URL) throws {
        log.withLock { $0.append((pthread_main_np() != 0, data)) }
        entered.signal()
        gate.wait()
        try RunMarkerFile.replaceAtomically(data, to: url)
    }

    func open(_ count: Int = 1) { for _ in 0..<count { gate.signal() } }
    /// Returns once a write has reached the gate.
    func waitForWrite() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { [entered] in
                entered.wait()
                continuation.resume()
            }
        }
    }
    var writes: [(main: Bool, data: Data)] { log.withLock { $0 } }
}

/// `RunMarkerFile`: the run marker's disk write never runs on the main
/// thread, a stuck disk never holds the caller, writes coalesce, and the
/// quit path can await one write with a deadline.
@MainActor
@Suite struct RunMarkerFileTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ folder: URL, _ writer: RunMarkerGatedWriter) -> RunMarkerFile {
        RunMarkerFile(url: folder.appending(path: "run.json"), signalURL: folder.appending(path: "run.signal"),
                      writer: { try writer.write($0, $1) })
    }

    /// The main thread only hands the bytes over: `submit` returns while
    /// the disk write is still blocked, and the write runs off the main
    /// thread.
    @Test(.timeLimit(.minutes(1)))
    func submitReturnsWhileTheDiskIsStuckAndWritesOffMain() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = RunMarkerGatedWriter()
        let marker = file(folder, writer)
        let clock = ContinuousClock()
        let started = clock.now
        let ticket = marker.submit(Data("a".utf8))
        #expect(clock.now - started < .milliseconds(50))
        #expect(await marker.written(ticket, timeout: .milliseconds(100)) == false)
        writer.open()
        #expect(await marker.written(ticket, timeout: .seconds(10)))
        #expect(writer.writes.map(\.main) == [false])
        #expect(try Data(contentsOf: folder.appending(path: "run.json")) == Data("a".utf8))
    }

    /// Writes queued behind a stuck one collapse into the newest bytes, and
    /// equal bytes are not written again.
    @Test(.timeLimit(.minutes(1)))
    func queuedWritesCoalesceToTheNewest() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = RunMarkerGatedWriter()
        let marker = file(folder, writer)
        marker.submit(Data("1".utf8))
        await writer.waitForWrite()
        var last: UInt64 = 0
        for text in ["2", "3", "4", "5"] { last = marker.submit(Data(text.utf8)) }
        writer.open(4)
        #expect(await marker.written(last, timeout: .seconds(10)))
        let again = marker.submit(Data("5".utf8))
        #expect(await marker.written(again, timeout: .seconds(10)))
        #expect(writer.writes.map { String(decoding: $0.data, as: UTF8.self) } == ["1", "5"])
        #expect(marker.writeCount == 2)
        #expect(try Data(contentsOf: folder.appending(path: "run.json")) == Data("5".utf8))
    }

    /// `close` waits for the write in progress, removes both files, and
    /// writes nothing after.
    @Test(.timeLimit(.minutes(1)))
    func closeRemovesTheFilesAndStopsWriting() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = RunMarkerGatedWriter()
        let marker = file(folder, writer)
        try Data().write(to: folder.appending(path: "run.signal"))
        let ticket = marker.submit(Data("x".utf8))
        writer.open()
        #expect(await marker.written(ticket, timeout: .seconds(10)))
        marker.close()
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "run.json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "run.signal").path))
        #expect(marker.submit(Data("y".utf8)) == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "run.json").path))
    }

    /// The real writer: a temporary file and a rename, no stray temporary
    /// file left, the old content replaced whole.
    @Test func replaceAtomicallyLeavesOnlyTheFile() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "run.json")
        try RunMarkerFile.replaceAtomically(Data("long old content".utf8), to: url)
        try RunMarkerFile.replaceAtomically(Data("new".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["run.json"])
    }
}
