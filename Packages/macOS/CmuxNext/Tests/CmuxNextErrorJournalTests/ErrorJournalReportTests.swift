import CmuxNextErrorJournal
import Foundation
import Testing

/// Copy Logs' text (the menu bar menu and Help): the header, then one line per entry with its
/// last-seen time, level, source, count and redacted sample, and its top frame under it.
struct ErrorJournalReportTests {
    private static func entry(_ sample: String, source: String = "app", level: ErrorLevel = .error, count: UInt64 = 1,
                              frame: String? = nil, lastMs: Int64 = 1_800_000_000_000) -> ErrorEntry {
        ErrorEntry(fingerprint: "0123456789abcdef", source: source, level: level, template: sample, sample: sample,
                   topFrame: frame, context: [:], count: count, firstMs: lastMs - 1000, lastMs: lastMs)
    }

    @Test func listsHeaderThenEntries() {
        let report = ErrorJournalReport(header: ["cmux 1.0 (42) com.cmuxterm.app.nightly", "macOS 26.0"], entries: [
            Self.entry("socket closed", source: "acpmux", level: .warning, count: 3),
            Self.entry("panicked at src/main.rs", source: "chief", level: .fault, frame: "main.rs:12"),
        ])
        #expect(report.text() == """
        cmux 1.0 (42) com.cmuxterm.app.nightly
        macOS 26.0

        2027-01-15T08:00:00Z warning acpmux ×3: socket closed
        2027-01-15T08:00:00Z fault chief ×1: panicked at src/main.rs
            at main.rs:12

        """)
    }

    @Test func anEmptyJournalSaysSo() {
        #expect(ErrorJournalReport(header: ["cmux"], entries: []).text() == "cmux\n\nNo problems recorded.\n")
    }
}
