/// What one viewer can show, reported to the source (presence).
///
/// For `.host` sources this is the viewer's vote in the smallest-viewer grid
/// rule (ghostty-next section 6): it counts only while `visible`. The
/// software keyboard never changes it. For `.local` sources it is the grid.
public struct TerminalViewport: Hashable, Sendable {
    public var cols: Int
    public var rows: Int
    /// On screen, scene foreground-active, device unlocked.
    public var visible: Bool

    /// - Parameters: `cols` and `rows` are clamped to at least 2 x 1.
    public init(cols: Int, rows: Int, visible: Bool) {
        self.cols = max(cols, 2)
        self.rows = max(rows, 1)
        self.visible = visible
    }
}
