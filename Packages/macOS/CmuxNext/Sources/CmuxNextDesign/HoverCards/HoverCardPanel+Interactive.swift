import AppKit

/// Whether the card takes clicks: an owner's card (the update highlights' "See all changes") or a target's card whose
/// body has a button (a tab card's Discard, `HoverCardBody.interactive`). Every other card lets the pointer's clicks
/// through to what it sits beside.
extension HoverCardPanel {
    /// The card takes clicks and scrolls now (a fading card takes none).
    var isInteractive: Bool { !ignoresMouseEvents }

    /// Whether the card takes clicks, scrolls and the pointer's moves.
    func setInteractive(_ interactive: Bool) {
        ignoresMouseEvents = !interactive
        acceptsMouseMovedEvents = interactive
    }

    /// A shown card's content changed (``refit()``); its new body may add or drop its button. A fading card stays
    /// out of the pointer's way.
    func refit(interactive: Bool) {
        guard isShowingCard else { return }
        setInteractive(interactive)
        refit()
    }
}
