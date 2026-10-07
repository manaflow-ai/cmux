/// Which tab separators the strip draws (TAB-STRIP-TRAILING-BUTTONS-REMOVED
/// amendment 2, Chrome's rule). Separator `i` is the line in the gap after
/// tab `i`; the last one sits between the last tab and the + button.
public struct TabSeparatorVisibility {
    public init() {}

    /// The separators that show in a row of `tabCount` tabs. Stub: every
    /// separator shows (the 8e9575bdbefd rule) until the Chrome rule lands.
    public static func visibleSeparators(tabCount: Int, selected: Int?, hovered: Int?, dragged: Int?) -> Set<Int> {
        Set(0..<max(tabCount, 0))
    }
}
