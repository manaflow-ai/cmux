/// When the strip's trailing buttons (new terminal, new browser, splits,
/// config actions) show. User feedback on nxdog9: only while the pointer is
/// over this pane's tab strip, while a menu the strip opened is up (the
/// pointer leaves for the menu), or while VoiceOver focuses one of them.
/// They keep their space either way, so tabs never move when they appear.
struct TabStripButtonReveal: Equatable, Sendable {
    var pointerInStrip = false
    var menuOpen = false
    var accessibilityFocused = false

    var isRevealed: Bool { pointerInStrip || menuOpen || accessibilityFocused }
}
