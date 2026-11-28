/// When the strip's plus shows (R120, user feedback on nxdog9): only while
/// the pointer is over this pane's tab strip, while a menu the strip opened
/// is up (the pointer leaves for the menu), or while VoiceOver focuses the
/// strip, one of its tabs or the plus (a VoiceOver user never hovers). The
/// plus keeps its space either way, so tabs never move when it appears.
struct TabStripButtonReveal: Equatable, Sendable {
    var pointerInStrip = false
    var menuOpen = false
    var accessibilityFocused = false

    var isRevealed: Bool { pointerInStrip || menuOpen || accessibilityFocused }
}
