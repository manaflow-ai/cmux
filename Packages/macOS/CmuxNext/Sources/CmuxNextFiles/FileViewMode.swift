/// How a Files pane lays out a folder (Finder's View menu).
public enum FileViewMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// A grid of icons or thumbnails (Cmd+1).
    case icons
    /// Rows with Name, Date Modified, Size and Kind columns (Cmd+2).
    case list
    /// Miller columns, one per folder of the path (Cmd+3).
    case columns
}
