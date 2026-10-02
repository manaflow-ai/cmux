/// cmux.json `layout.closeFocus`: which pane gets focus when the focused
/// pane closes (plans/cmux-next/close-focus.md, REWRITE.md round 5).
public nonisolated enum CloseFocusPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    /// The previous pane in the same column, else the next one there; when
    /// the column goes, the column to the left, else the one to the right.
    case previousNeighbor
    /// The most recently focused surviving pane, else `previousNeighbor`.
    case mostRecent

    /// Parses the cmux.json value (case-insensitive raw value).
    public init?(configValue: String) {
        guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == configValue.lowercased() }) else { return nil }
        self = match
    }
}
