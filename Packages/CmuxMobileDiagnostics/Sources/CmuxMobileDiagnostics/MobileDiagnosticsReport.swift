public import Foundation

/// A built diagnostics report: the scrubbed text plus the temp file it was
/// written to for sharing.
///
/// ``MobileDiagnosticsReportBuilder/buildReport(liveState:terminalSnapshot:)``
/// returns this so the UI can both copy ``text`` to the clipboard and hand
/// ``fileURL`` to a `ShareLink` (sharing a `.txt` file shares large logs cleanly
/// to Mail/Files, unlike a giant in-memory string).
public struct MobileDiagnosticsReport: Sendable {
    /// The fully assembled, scrubbed report text.
    public let text: String
    /// A temp-directory `.txt` file containing ``text``, suitable for `ShareLink`.
    public let fileURL: URL

    /// Creates a report value.
    ///
    /// - Parameters:
    ///   - text: The scrubbed report text.
    ///   - fileURL: The temp `.txt` file the text was written to.
    public init(text: String, fileURL: URL) {
        self.text = text
        self.fileURL = fileURL
    }
}
