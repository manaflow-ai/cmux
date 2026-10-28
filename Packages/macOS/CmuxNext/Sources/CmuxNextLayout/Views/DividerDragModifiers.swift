import AppKit

/// The modifier keys held during a divider or column-edge drag, read as resize modes
/// (plans/cmux-next/resize-modifiers.md). They are read from every drag event and from
/// `flagsChanged`, so pressing or letting go of a key mid-drag changes the mode at once.
struct DividerDragModifiers: Equatable {
    /// Option: a split divider in a scrolling column grows the column and pushes the columns after
    /// it; a column edge trades width with the next column.
    var push = false
    /// Command: a column edge gives every scrolling column its width; a split divider evens the
    /// panes on both of its sides.
    var all = false
    /// Shift: lands only on a snap (halves, thirds, the equal share; column width presets).
    var snap = false
    /// Control: the divider moves at ``fineScale`` of the pointer's speed.
    var fine = false

    /// How far a divider moves per point of pointer travel with Control held.
    static let fineScale: CGFloat = 0.25

    init(push: Bool = false, all: Bool = false, snap: Bool = false, fine: Bool = false) {
        self.push = push
        self.all = all
        self.snap = snap
        self.fine = fine
    }

    init(_ flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        // Command wins over Option: both at once read as Command (every column), never a mix.
        all = flags.contains(.command)
        push = flags.contains(.option) && !all
        snap = flags.contains(.shift)
        fine = flags.contains(.control)
    }

    var isEmpty: Bool { self == DividerDragModifiers() }
}
