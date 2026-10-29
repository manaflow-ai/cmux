import Foundation
import Testing
@testable import CmuxNextErrorJournal

/// p10-stability-029 regressions: damaged harvest inputs (a cursor in `cursors.json`, a file in
/// the reports folder) give a fresh start or a skip. Before the fix each one trapped, waited
/// forever, hid every later report or read the whole folder.
@Suite struct DamagedHarvestInputTests {
    private let directory: URL = {
        let url = FileManager().temporaryDirectory.appendingPathComponent("damaged-harvest-\(UUID().uuidString)")
        try? FileManager().createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let report = """
    {"app_name":"cmux NEXT Nightly","app_version":"0.70.0","bug_type":"309","incident_id":"X"}
    {"exception" : {"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"threads":[{"frames":[{"symbol":"main"}]}]}
    """

    private func writeReport(_ name: String, modified: Date? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(Self.report.utf8).write(to: url)
        if let modified { try FileManager().setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    /// NaN or 1e300 trapped in `Int64(_:)`; "99999999999999" (year 5138) hid every later report;
    /// "-5" (1970) skipped the first-harvest look back and read the month-old report too.
    @Test func aDamagedCrashReportCursorStartsOver() async throws {
        _ = try writeReport("cmux-2026-09-20.ips", modified: Date().addingTimeInterval(-30 * 86400))
        let recent = try writeReport("cmux-2026-10-20.ips")
        let source = CrashReportErrorSource(directory: directory)
        for cursor in ["nan", "inf", "-inf", "1e400", "1e300", "-1e300", "not a number", "99999999999999", "-5"] {
            let harvest = try await source.collect(after: cursor)
            #expect(harvest.events.map { $0.context["report"] } == [recent.path], "cursor \(cursor)")
            #expect(harvest.cursor.flatMap { Int64($0) } != nil, "cursor \(cursor)")
        }
    }

    /// A report dated after now (written while the clock was set ahead) became the cursor, and
    /// the next harvest started from that future date. It waits for its date instead.
    @Test func aReportFromTheFutureDoesNotMoveTheCursorPastNow() async throws {
        _ = try writeReport("cmux-ahead.ips", modified: Date().addingTimeInterval(86400))
        let source = CrashReportErrorSource(directory: directory)
        let first = try await source.collect(after: nil)
        #expect(first.events.isEmpty)
        let cursor = try #require(first.cursor.flatMap { Int64($0) })
        #expect(Double(cursor) <= (Date().timeIntervalSince1970 + 3600) * 1000)
    }

    /// `UInt64(-5)` trapped at the seek.
    @Test func aDamagedLogCursorStartsOver() async throws {
        let log = directory.appendingPathComponent("daemon.log")
        try Data("ERROR first\n".utf8).write(to: log)
        let attributes = try FileManager().attributesOfItem(atPath: log.path)
        let inode = try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        let source = LogFileErrorSource(url: log, source: "acpmux")
        let harvest = try await source.collect(after: "\(inode):-5")
        #expect(harvest.events.map(\.message) == ["first"])
        #expect(harvest.cursor == "\(inode):12")
    }

    /// The log parser cuts its captures by UTF-16 counts from the front (no subscript);
    /// characters outside the Basic Multilingual Plane before and inside a capture come out whole.
    @Test func aLogLineWithWideCharactersParsesWhole() {
        let parser = LogLineParser(source: "acpmux", file: "daemon.log")
        let events = parser.events(in: "🙂 é ERROR: boom 🙂\nthread 'main' panicked at src/🙂.rs:10:5:\nit broke\n")
        #expect(events.map(\.message) == ["boom 🙂", "panic: it broke"])
        #expect(events.map(\.topFrame) == [nil, "src/🙂.rs:10"])
    }

    /// The first harvest of a log starts mid-line: the part line before its first break is dropped, and only
    /// complete lines are read (a partial last line waits for its newline).
    @Test func aFirstHarvestDropsThePartLineAndWaitsForTheLastOne() async throws {
        let log = directory.appendingPathComponent("tail.log")
        // 47 bytes; the last 36 start inside "x ERROR cut".
        try Data("ERROR old\nx ERROR cut\nERROR whole\nERROR partial".utf8).write(to: log)
        let source = LogFileErrorSource(url: log, source: "acpmux", firstReadBytes: 36)
        let harvest = try await source.collect(after: nil)
        #expect(harvest.events.map(\.message) == ["whole"])
        let attributes = try FileManager().attributesOfItem(atPath: log.path)
        let inode = try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        #expect(harvest.cursor == "\(inode):34")
    }

    /// Opening a FIFO waited in open(2) for a writer that never came. The test supplies one
    /// that opens and closes as soon as a reader appears, so a harvest that opens the FIFO
    /// reads end of file and reports it (a failure, not a hang); then the test is that reader.
    @Test(.timeLimit(.minutes(1))) func aFIFONamedLikeAReportIsSkipped() async throws {
        let fifo = directory.appendingPathComponent("cmux-fifo.ips").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let report = try writeReport("cmux-real.ips")
        async let writer: Void = Self.openAndCloseWriter(fifo)
        let harvest = try await CrashReportErrorSource(directory: directory).collect(after: nil)
        let reader = open(fifo, O_RDONLY | O_NONBLOCK)
        await writer
        if reader >= 0 { close(reader) }
        #expect(harvest.events.map { $0.context["report"] } == [report.path])
    }

    /// Opens `path` for writing and closes it, on a thread of its own: a FIFO's open(2) waits
    /// for a reader, and that wait must not hold a cooperative thread.
    private static func openAndCloseWriter(_ path: String) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread {
                let fd = open(path, O_WRONLY)
                if fd >= 0 { close(fd) }
                done.resume()
            }.start()
        }
    }
}
