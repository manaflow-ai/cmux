/// Which tab separators the strip draws (TAB-STRIP-TRAILING-BUTTONS-REMOVED
/// amendment 2, Chrome's rule). Separator `i` is the line in the gap after
/// tab `i`; the last one sits between the last tab and the + button.
public struct TabSeparatorVisibility {
    public init() {}

    /// The separators that show in a row of `tabCount` tabs. A separator
    /// shows only when neither neighbor is selected, hovered or dragged, so
    /// each of those tabs hides the separators on both of its sides. The
    /// separator before + has one neighbor tab, the last one. Indices
    /// outside the row are ignored.
    public static func visibleSeparators(tabCount: Int, selected: Int?, hovered: Int?, dragged: Int?) -> Set<Int> {
        guard tabCount > 0 else { return [] }
        let emphasized = Set([selected, hovered, dragged].compactMap(\.self))
        var visible: Set<Int> = []
        for index in 0..<tabCount where !emphasized.contains(index) && !emphasized.contains(index + 1) {
            visible.insert(index)
        }
        return visible
    }
}
