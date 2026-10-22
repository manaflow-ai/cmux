import AppKit
import CmuxNextCompat
import CmuxNextCookieImport

/// A Chief's cookie import ask, inline in its Home conversation: the permission card
/// (`CookieImportCardView`) above the composer, until the person closes it.
extension HomeHostView {
    /// A Chief conversation the person can see now: in a visible, unoccluded window and not hidden.
    var canShowCookieImport: Bool {
        guard isChief, let window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
        return !isHiddenOrHasHiddenAncestor
    }

    /// Shows `ask`'s card in this conversation and takes it down once the ask is dismissed.
    func showCookieImport(_ ask: CookieImportAsk) {
        let card = CookieImportCardView(ask: ask)
        transcript.setAsk(card) { [weak card] width in card?.height(for: width) ?? 0 }
        // task-owner: lives until the ask is dismissed; event-driven (Observation)
        Task { @MainActor [weak self, weak card] in
            for await dismissed in ObservationStream({ ask.isDismissed }) where dismissed { break }
            card?.stop()
            if let self, transcript.currentAsk === card { transcript.setAsk(nil, height: nil) }
        }
    }
}
