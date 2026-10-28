@testable import CmuxScreenKit
import Foundation
import Testing

/// The timing log opens and appends to its file on its own queue, never on the main actor that
/// records the timings, and keeps the lines in the order they were recorded.
struct ScreenPerfLogFileTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("screen-perf-\(UUID().uuidString).log")
    }

    private func flushed(_ file: ScreenPerfLogFile) async {
        await withCheckedContinuation { continuation in file.flush { continuation.resume() } }
    }

    @Test func appendsLinesInOrderToANewFile() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = ScreenPerfLogFile(url: url)
        for index in 0 ..< 50 { file.append(Data("\(index)\n".utf8)) }
        await flushed(file)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == (0 ..< 50).map(String.init))
    }

    @Test func appendsAfterWhatTheFileHeld() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("old\n".utf8).write(to: url)
        let file = ScreenPerfLogFile(url: url)
        file.append(Data("new\n".utf8))
        await flushed(file)
        #expect(try String(contentsOf: url, encoding: .utf8) == "old\nnew\n")
    }

    @MainActor
    @Test func theMainActorLogReturnsBeforeTheFileIsOpened() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ScreenPerfLog(file: url)
        log.input("tap")
        // Nothing above touched the disk on the main actor: the session line and the input line land once the log's
        // queue runs, in order.
        await withCheckedContinuation { continuation in log.flushForTesting { continuation.resume() } }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first?.contains("\"session\"") == true)
        #expect(lines.last?.contains("\"tap\"") == true)
    }
}
