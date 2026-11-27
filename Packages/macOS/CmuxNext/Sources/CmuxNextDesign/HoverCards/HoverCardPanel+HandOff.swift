import AppKit

// NIGHTLY crash 2026-11-25 (SIGABRT, NSGenericException "Unable to activate constraint with anchors
// WorkspaceHoverCardView.top and NSView.top because they have no common ancestor", in `finishMorph` run by
// `dismiss`'s fade-out). A source reuses its one body view. `HoverCardCoordinator.cardWindow(for:)` retires the
// shown card window when another source's card takes it and makes a fresh one; when the first source shows again,
// the fresh window installs the same view, and `addSubview` moves it out of the retired window, which (still fading
// out, mid-morph) kept its body and edge constraints on it. Its fade's end re-activated them across two windows.
extension HoverCardPanel {
    /// Another card window takes `view` out of this one: this card drops every claim it has on it. A morph in
    /// flight lays the card out at rest now, while the view is still here (a fold's held layout ends with it); then
    /// the card forgets the view, its constraints and a refit that waited for the morph. A parked or leaving view is
    /// forgotten too (shown again), so this card's `endLeaving` never takes it out of the card that shows it now.
    func giveUp(_ view: NSView) {
        if leavingBody === view || parkedBody === view {
            if leavingBody === view { leavingBody = nil }
            if parkedBody === view { parkedBody = nil }
            view.isHidden = false
        }
        guard body === view else { return }
        finishMorph()
        NSLayoutConstraint.deactivate(edgeConstraints + sizeConstraints)
        edgeConstraints = []
        sizeConstraints = []
        pendingRefit = nil
        body = nil
    }
}
