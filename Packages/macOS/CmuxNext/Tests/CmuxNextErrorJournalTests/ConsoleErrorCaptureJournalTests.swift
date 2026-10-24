@testable import CmuxNextErrorJournal
import Foundation
import Testing

/// A page's console error is in the journal when it happens: before, the capture only wrote it to
/// the unified log, and the journal found it at the next harvest, which ran every 300 s (an
/// `OSLogStore` read, 1.4 s on a loaded machine). A crash in between lost it, since the log store
/// of a process that ended cannot be read by the next launch.
@MainActor
@Suite struct ConsoleErrorCaptureJournalTests {
    private let directory = FileManager().temporaryDirectory.appendingPathComponent("console-capture-\(UUID().uuidString)")

    @Test func aReportIsInTheJournalWithoutAHarvest() async throws {
        let journal = ErrorJournal(directory: directory)
        let capture = ConsoleErrorCapture(page: "settings", recorder: journal)
        await capture.record(["level": "warn", "message": "theme missing token=abc123secret\nmore",
                              "stack": "Error\n    at load (cmux-page://settings/main.js:4:9)"])?.value
        await journal.flush()

        // Another journal on the folder (the next launch) reads it from disk.
        let entry = try #require(await ErrorJournal(directory: directory).entries().first)
        #expect(entry.source == "page:settings")
        #expect(entry.level == .warning)
        // The same text and fingerprint the log harvest gave it (`OSLogErrorSource.event`).
        #expect(entry.sample.hasPrefix("[warn] theme missing token=<redacted>"))
        #expect(entry.topFrame == "load (cmux-page://settings/main.js:4:9)")
    }

    @Test func aBodyThatIsNotAReportRecordsNothing() async {
        let journal = ErrorJournal(directory: directory)
        #expect(ConsoleErrorCapture(page: "settings", recorder: journal).record("not an object") == nil)
        #expect(await journal.entryCount == 0)
    }
}
