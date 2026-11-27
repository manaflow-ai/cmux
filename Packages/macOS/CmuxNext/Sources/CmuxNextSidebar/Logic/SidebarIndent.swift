import CoreGraphics

/// The one rule for how far a sidebar row moves in for its group level (nested-groups prototype).
///
/// Every x a row, a members' rail, a lifted card or a drop line takes comes from here, from
/// the row's level from the groups the list holds (`SidebarRow.indentLevel`), so two rows at the same
/// level always share one x, in any group, after a drag and after a reload. A level past
/// ``visualCap(width:)`` draws at the cap: in a narrow sidebar the labels keep their width.
nonisolated struct SidebarIndent: Hashable, Sendable {
    /// One level's step: the members' gutter (`SidebarStyle.groupGutter`).
    var step: CGFloat
    /// The label width a row keeps at its deepest drawn level: in a narrow sidebar the indent stops before a
    /// label gets narrower than this.
    var minimumLabelWidth: CGFloat = 150
    /// Steps past this never move in more, whatever the width. Six steps draw a seven-level tree with every
    /// level at its own x in the default sidebar (Lawrence 2026-10-23: "i want to see deeply nested groups");
    /// deeper levels share the deepest x, and still nest.
    var maxVisualLevels = 6

    /// How many steps in the deepest drawn level may go, for a row `width` wide at level 0.
    func visualCap(width: CGFloat) -> Int {
        guard step > 0 else { return 0 }
        // Clamped before the Int conversion: an unbounded width (`SidebarRow.groupGutter`) must not trap.
        let fits = min(Double(maxVisualLevels), max(0, ((width - minimumLabelWidth) / step).rounded(.down)))
        return max(1, Int(fits))
    }

    /// The x offset of a row at `level`, from the list's leading inset. Level 1 (a top-level group's
    /// members) keeps level 0's x: grouped rows line up with ungrouped ones (Leo 2026-10-21, #23975), the
    /// group's rail sits in the inset beside them. Each deeper level is one step further in, up to the cap.
    func offset(level: Int, width: CGFloat) -> CGFloat {
        CGFloat(min(max(0, level - 1), visualCap(width: width))) * step
    }

    /// The level a pointer at `x` (from the list's leading inset) points at, in `range`: a drop
    /// at a block's bottom edge goes to the level its x picks, like an outliner.
    func level(atX x: CGFloat, width: CGFloat, in range: ClosedRange<Int>) -> Int {
        guard step > 0 else { return range.lowerBound }
        let cap = visualCap(width: width)
        // Level L >= 1 sits at (L - 1) steps (`offset`), level 0 shares level 1's x: a pointer in the first half
        // step picks 0 (out of the top-level group), the rest of that step 1, then each step one level deeper.
        let picked = x < step / 2 ? 0 : Int((x / step).rounded(.down)) + 1
        // Past the cap every level shares one x: the deepest allowed one wins there.
        let level = picked - 1 >= cap ? range.upperBound : picked
        return min(range.upperBound, max(range.lowerBound, level))
    }
}
