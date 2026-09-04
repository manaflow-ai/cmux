/// Admission to the process-wide lane for a concrete pasteboard.
public enum TerminalPasteboardReadAdmission: Sendable {
    /// The pasteboard is named, test-only, or otherwise outside the shared lane.
    case unmanaged

    /// The read was admitted and must finish its lease after materialization.
    case reserved(TerminalPasteboardReadLease)

    /// The bounded lane could not retain another operation.
    case rejected
}
