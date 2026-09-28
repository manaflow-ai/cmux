/// The viewport rows where an agent draws its live UI, so a bare key hint
/// there (`esc to interrupt`, `↓ to manage`, `Tab to amend`) presses a key
/// the live UI offers.
///
/// Claude Code, Codex, and OpenCode draw their live UI at the bottom of their
/// output around the terminal cursor: the status line (`esc to interrupt`)
/// sits just above the input box that holds the cursor, the footer (`? for
/// shortcuts`, `shift+tab to cycle`) sits below it, and a permission prompt
/// ends with its hint line (`Esc to cancel · Tab to amend`) where the input
/// box was. So the live region is every visible row from
/// ``rowsAboveCursor`` rows above the cursor row down to the bottom of the
/// viewport. Rows further up hold transcript and prose.
///
/// There is no live region while the viewport is scrolled back or the
/// cursor is off screen: the visible rows are then all history.
public struct AgentKeyHintLiveRegion: Sendable, Equatable {
    /// Rows above the cursor row that still count as live: the input box's
    /// top border and a few lines of multi-line input, a blank row, and the
    /// status line above them.
    public static let rowsAboveCursor = 8

    /// The first live viewport row, or `nil` when no row is live.
    public let firstRow: Int?

    /// - Parameters:
    ///   - viewportAtBottom: Whether the viewport shows the bottom of the
    ///     scrollback, not history.
    ///   - cursorRow: The cursor's viewport row, or `nil` when the cursor is
    ///     not in the viewport.
    public init(viewportAtBottom: Bool, cursorRow: Int?) {
        guard viewportAtBottom, let cursorRow, cursorRow >= 0 else {
            firstRow = nil
            return
        }
        firstRow = max(0, cursorRow - Self.rowsAboveCursor)
    }

    /// Whether viewport row `row` is live.
    public func contains(row: Int) -> Bool {
        guard let firstRow else { return false }
        return row >= firstRow
    }
}
