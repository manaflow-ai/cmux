/// When the strip's plus shows (R120, user feedback on nxdog9): only while
/// the pointer is over this pane's tab strip or while a menu the strip
/// opened is up (the pointer leaves for the menu). The plus keeps its space
/// either way, so tabs never move when it appears.
struct TabStripButtonReveal: Equatable, Sendable {
    var pointerInStrip = false
    var menuOpen = false

    var isRevealed: Bool { pointerInStrip || menuOpen }
}
