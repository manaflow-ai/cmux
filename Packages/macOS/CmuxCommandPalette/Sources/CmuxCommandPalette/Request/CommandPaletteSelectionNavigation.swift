/// The window-agnostic decision of whether a candidate selection-move delta
/// should be routed to the visible command palette.
///
/// The app target computes a candidate `delta` (`+1`/`-1`/`nil`) from the
/// keystroke, then asks whether the palette should handle it. Selection
/// navigation is routed only when the palette is interactive and is not
/// currently using inline text handling (a multiline editor consumes arrow
/// keys itself). Keeping this policy as a value type avoids a free function and
/// keeps it pure and testable.
public struct CommandPaletteSelectionNavigation: Sendable, Equatable {
    /// The candidate selection-move delta, or `nil` when the keystroke produced none.
    public let delta: Int?
    /// Whether the palette is currently interactive in the target window.
    public let isInteractive: Bool
    /// Whether the palette is routing the keystroke through an inline text editor.
    public let usesInlineTextHandling: Bool

    /// Creates a selection-navigation routing decision input.
    public init(delta: Int?, isInteractive: Bool, usesInlineTextHandling: Bool) {
        self.delta = delta
        self.isInteractive = isInteractive
        self.usesInlineTextHandling = usesInlineTextHandling
    }

    /// Whether the candidate delta should be routed to the palette.
    public var shouldRoute: Bool {
        guard delta != nil, isInteractive else { return false }
        return !usesInlineTextHandling
    }
}
