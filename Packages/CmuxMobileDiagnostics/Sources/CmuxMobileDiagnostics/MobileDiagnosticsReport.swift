/// A built diagnostics report containing the fully scrubbed text.
///
/// ``MobileDiagnosticsReportBuilder/buildReport(liveState:terminalSnapshot:)``
/// returns this so the UI can copy ``text`` to the clipboard, hand it to a
/// `ShareLink`, or attach it to the feedback flow.
public struct MobileDiagnosticsReport: Sendable {
    /// The fully assembled, scrubbed report text.
    public let text: String

    /// Creates a report value.
    ///
    /// - Parameter text: The scrubbed report text.
    public init(text: String) {
        self.text = text
    }
}
