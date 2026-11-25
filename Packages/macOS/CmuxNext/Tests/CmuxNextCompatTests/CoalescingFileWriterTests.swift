import CmuxNextCompat
import Foundation
import Testing

/// "resource: disk writes" hang-watch reports (cmuxterm-hq hq#11120, #13152): a store that saves its
/// whole file per change writes far more than macOS's disk budget. One writer keeps the newest bytes
/// per path and writes them once per window, off the caller's thread.
struct CoalescingFileWriterTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "coalescing-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func aThousandSavesAreAHandfulOfWritesAndTheNewestWins() throws {
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "store.json")
        let writer = CoalescingFileWriter(window: 0.05)
        let big = String(repeating: "x", count: 512 * 1024)
        let clock = ContinuousClock()
        let spent = clock.measure {
            for index in 0..<1000 { writer.write(Data("\(index) \(big)".utf8), to: file) }
        }
        writer.flush()
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("999 "))
        #expect(writer.diskWrites <= 5, "disk writes: \(writer.diskWrites)")
        #expect(!writer.isBusy)
        // Handing over 1,000 half-megabyte saves is bytes in a dictionary, not disk: per call, well under a frame.
        #expect(spent < .milliseconds(1000), "caller spent \(spent)")
        print("coalescing: 1000 saves -> \(writer.diskWrites) disk writes, caller \(spent)")
    }

    @Test func appendsJoinAndRotate() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "log.ndjson"), older = dir.appending(path: "log.1.ndjson")
        let writer = CoalescingFileWriter(window: 0.05)
        for _ in 0..<100 { writer.append(Data("0123456789\n".utf8), to: file, rotatingTo: older, limit: 400) }
        writer.flush()
        for _ in 0..<100 { writer.append(Data("0123456789\n".utf8), to: file, rotatingTo: older, limit: 400) }
        writer.flush()
        #expect(writer.diskWrites <= 4)
        #expect(FileManager.default.fileExists(atPath: older.path))
    }

    @Test func aNilRemovesTheFile() throws {
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "a.json")
        let writer = CoalescingFileWriter(window: 0.01)
        writer.write(Data("a".utf8), to: file)
        writer.flush()
        writer.save(to: file) { nil }
        writer.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
