/// A sanitized failure encountered while reading Cursor's local session data.
public enum CursorSessionIndexError: Hashable, Sendable {
    /// Cursor's projects hierarchy could not be enumerated completely.
    case projectsDirectoryUnreadable
    /// At least one discovered Cursor transcript could not be read as UTF-8 text.
    case transcriptUnreadable
}
