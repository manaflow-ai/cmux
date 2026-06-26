/// Which terminal-text source produced a command-click word path resolution.
///
/// Command-click path resolution consults more than one source: Ghostty's
/// QuickLook word extraction and a pointer/offset-anchored snapshot of the
/// visible grid. The raw values are stable strings used in runtime debug
/// payloads.
public enum WordPathResolutionSource: String, Sendable {
    /// Resolved from Ghostty's QuickLook word under the cursor.
    case quicklook
    /// Resolved from a snapshot of the visible terminal grid.
    case snapshot
}
