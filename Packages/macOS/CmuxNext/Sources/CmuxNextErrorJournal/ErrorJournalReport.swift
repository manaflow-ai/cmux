public import Foundation

/// The journal as plain text for a bug report (Help > Copy Logs, the menu bar's Copy Logs): the
/// header lines (build, macOS, where the logs are), then one line per entry, newest first. The
/// samples are already redacted and bounded (``ErrorRedactor``), so the text is safe to paste.
///
/// ```swift
/// let report = ErrorJournalReport(header: ["cmux 0.65.2 (1234) com.cmuxterm.app.nightly"],
///                                 entries: await journal.entries(ErrorQuery(limit: 100)))
/// NSPasteboard.general.setString(report.text(), forType: .string)
/// ```
public struct ErrorJournalReport: Sendable {
    /// The lines above the entries.
    public var header: [String]
    /// The entries, in the order the report lists them.
    public var entries: [ErrorEntry]

    /// - Parameters:
    ///   - header: Lines above the entries (build, system, log folder).
    ///   - entries: The journal entries to list, in order.
    public init(header: [String], entries: [ErrorEntry]) {
        self.header = header
        self.entries = entries
    }

    /// The report: the header, a blank line, then `last-seen level source ×count: sample`
    /// lines with the top frame indented under its entry; a journal with no entry says so.
    public func text() -> String {
        let request: [String: Any] = ["header": header, "entries": ErrorJournalFFI.json(entries)]
        return ErrorJournalFFI.object("error_journal_report_text", request)?["text"] as? String
            ?? header.joined(separator: "\n") + "\n"
    }
}
