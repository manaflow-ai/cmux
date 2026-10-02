/// cmux.json `layout.closeFocus`: which pane gets focus when the focused
/// pane closes (plans/cmux-next/close-focus.md, REWRITE.md round 5).
public nonisolated enum CloseFocusPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    /// The previous pane in the same column, else the next one there; when
    /// the column goes, the column to the left, else the one to the right.
    case previousNeighbor
    /// The most recently focused surviving pane, else `previousNeighbor`.
    case mostRecent

    /// Parses the cmux.json value; "previous" and "recent" are accepted too.
    public init?(configValue: String) {
        switch configValue.lowercased() {
        case "previousneighbor", "previous", "neighbor": self = .previousNeighbor
        case "mostrecent", "recent", "history": self = .mostRecent
        default: return nil
        }
    }
}
