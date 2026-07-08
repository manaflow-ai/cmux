import Foundation
import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDebugLogFileTests {
    @Test func writesHeaderAndAppendedLinesImmediately() async throws {
        let logURL = makeLogURL()
        defer { removeLogFiles(at: logURL) }
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let clock = DateSequence([
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 101.25),
            Date(timeIntervalSince1970: 103.5),
        ])
        let sink = MobileDebugLogSink(
            now: { clock.next() },
            fileURL: logURL,
            fileHeader: "h"
        )

        await sink.append("one")
        await sink.append("two")

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        #expect(contents == """
        h
        [    1.250] one
        [    3.500] two

        """)
    }

    @Test func rotatesExistingLogAndReplacesPreviousRotation() async throws {
        let logURL = makeLogURL()
        let rotatedURL = rotatedLogURL(for: logURL)
        defer { removeLogFiles(at: logURL) }
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "old\n".write(to: logURL, atomically: true, encoding: .utf8)
        try "stale rotation\n".write(to: rotatedURL, atomically: true, encoding: .utf8)

        let clock = DateSequence([
            Date(timeIntervalSince1970: 10),
            Date(timeIntervalSince1970: 11),
        ])
        let sink = MobileDebugLogSink(
            now: { clock.next() },
            fileURL: logURL,
            fileHeader: "new"
        )
        await sink.append("fresh")

        let current = try String(contentsOf: logURL, encoding: .utf8)
        let rotated = try String(contentsOf: rotatedURL, encoding: .utf8)
        #expect(current == """
        new
        [    1.000] fresh

        """)
        #expect(rotated == "old\n")
    }

    @Test func missingDirectoryDisablesFileWritesButKeepsBuffering() async {
        let logURL = makeLogURL()
            .deletingLastPathComponent()
            .appendingPathComponent("missing")
            .appendingPathComponent("cmux-debug.log")
        defer { removeLogFiles(at: logURL.deletingLastPathComponent()) }

        let sink = MobileDebugLogSink(fileURL: logURL, fileHeader: "h")
        await sink.append("survives")

        let result = await sink.snapshotWithCount()
        #expect(result.count == 1)
        #expect(result.body.hasSuffix("survives"))
        #expect(!FileManager.default.fileExists(atPath: logURL.path))
    }

    @Test func clearLeavesFileContentsIntact() async throws {
        let logURL = makeLogURL()
        defer { removeLogFiles(at: logURL) }
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let clock = DateSequence([
            Date(timeIntervalSince1970: 50),
            Date(timeIntervalSince1970: 52),
        ])
        let sink = MobileDebugLogSink(
            now: { clock.next() },
            fileURL: logURL,
            fileHeader: "h"
        )
        await sink.append("kept on disk")
        await sink.clear()

        let result = await sink.snapshotWithCount()
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        #expect(result.count == 0)
        #expect(result.body.isEmpty)
        #expect(contents == """
        h
        [    2.000] kept on disk

        """)
    }

    private func makeLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-mobile-debug-log-tests-\(UUID().uuidString)")
            .appendingPathComponent("cmux-debug.log")
    }

    private func rotatedLogURL(for logURL: URL) -> URL {
        URL(fileURLWithPath: logURL.path + ".1")
    }

    private func removeLogFiles(at logURL: URL) {
        try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: rotatedLogURL(for: logURL))
    }

    /// A deterministic clock that returns the supplied dates in order.
    ///
    /// Mutation is serialized through an `NSLock` confined to this test fixture;
    /// it never escapes the suite and is read serially by the sink under test.
    private final class DateSequence: @unchecked Sendable {
        private let dates: [Date]
        private let lock = NSLock()
        private var index = 0

        init(_ dates: [Date]) {
            self.dates = dates
        }

        func next() -> Date {
            lock.lock()
            defer { lock.unlock() }
            defer { index += 1 }
            return dates[min(index, dates.count - 1)]
        }
    }
}
