public import AppKit

extension NSMenu {
    /// Draws this menu's rows in `scope`'s accent instead of the system accent (follow-up to
    /// #19754). Not yet implemented: the menu keeps AppKit's rows.
    public func themeRows(in scope: ThemeScope) {}
}

/// A cmux-drawn menu row.
public final class ThemedMenuRowView: NSView {
    /// Draws the row highlighted (or not) without a tracking menu (tests).
    var highlightOverride: Bool?
}
