import CmuxNextControl
import Darwin
import Foundation
import Testing

/// The startup bench reads each launch mark as a line. It passed a descriptor (`CMUX_NEXT_LAUNCH_MARKS_FD`), which only
/// a child the bench spawns itself can inherit. A launch through LaunchServices (`open`, as a Dock click), which makes
/// the app the active app as a person's launch does, has no inherited descriptors: the bench names a FIFO instead
/// (`CMUX_NEXT_LAUNCH_MARKS_PATH`), and the app writes the same lines to it.
@Suite struct LaunchMarkSinkTests {
    @Test func marksGoToTheNamedFIFO() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "marks-\(UUID().uuidString).fifo").path
        try #require(mkfifo(path, 0o600) == 0, "mkfifo failed")
        defer { unlink(path) }
        // The bench opens its end first, as bench-startup.py does.
        let reader = open(path, O_RDONLY | O_NONBLOCK)
        try #require(reader >= 0)
        defer { close(reader) }
        let sink = LaunchMarkSink(environment: [LaunchMarkSink.pathKey: path])
        sink.write(name: "main_start", ms: 12.5)
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(reader, &buffer, buffer.count)
        #expect(count > 0, "nothing came through the FIFO")
        #expect(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self) == "main_start 12.5\n")
    }

    /// No reader (the bench is gone): the sink writes nothing and never blocks the launch on the open.
    @Test func aFIFOWithNoReaderIsIgnored() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "marks-\(UUID().uuidString).fifo").path
        try #require(mkfifo(path, 0o600) == 0, "mkfifo failed")
        defer { unlink(path) }
        let sink = LaunchMarkSink(environment: [LaunchMarkSink.pathKey: path])
        sink.write(name: "main_start", ms: 1) // must return at once
    }
}
