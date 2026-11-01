import CmuxNextWakeups
import CmuxUpdater
public import Foundation

/// The update status on the sidebar's shared notice card (Lawrence
/// 2026-10-09): its content for this build, its buttons, its x, and the up
/// to date notice hiding itself on the injected clock.
extension UpdaterService {

    /// The card's icon, text and actions for the running build, or nil.
    public var cardPresentation: UpdateCardPresentation? {
        guard let card else { return nil }
        var shown = card.presentation(version: identity.shortVersion, build: identity.build,
                                      install: card == .installing ? installStatus : nil)
        switch card {
        case .available, .note(.found):
            // The found build's short version, date and first changelog lines.
            if let changelog = foundChangelog {
                shown.detail = changelog.detail ?? shown.detail
                shown.lines = changelog.lines
            }
        case .checking, .downloading, .installing, .note, .gettingNewest:
            break
        }
        return shown
    }

    /// The found update's release notes: its GitHub release or commit, else
    /// the releases page; nil without a found update.
    public var cardReleaseNotesURL: URL? {
        let version: String?
        switch card {
        case .available(let found): version = found
        case .note(.found(let found)): version = found
        case .checking, .downloading, .installing, .note, .gettingNewest, nil: return nil
        }
        return version.flatMap { UpdateState.ReleaseNotes(displayVersionString: $0)?.url }
            ?? URL(string: "https://github.com/manaflow-ai/cmux/releases")
    }

    /// A notice button. Release Notes is a link the App opens
    /// (``cardReleaseNotesURL``); the others act here.
    public func performCardAction(_ action: UpdateCardAction) {
        switch action {
        case .update: downloadClicked()
        case .retry: checkForUpdates()
        case .details: presentUpdateUI?()
        case .cancelDownload: cancelDownloadClicked()
        case .releaseNotes: break
        }
    }

    /// The notice's x without its menu: a found update hides until a newer
    /// one (``closeUpdateCard(_:)``); a result clears (as when it times out).
    public func dismissCard() {
        switch card {
        case .available:
            closeUpdateCard(.hideVersion)
        case .note:
            dismissIndicatorNote()
        case .installing:
            // Only the card of an install that never relaunched has an x.
            if installStatus?.stage == .stalled { installCardDismissed = true }
        case .checking, .downloading, .gettingNewest, nil:
            break
        }
        followCardExpiry()
    }

    /// Schedules the shown card's timeout (up to date), once per card, or
    /// cancels it when the card changed to one that waits.
    func followCardExpiry() {
        let shown = card
        #if DEBUG || CMUX_BENCH_HOOKS
        // The update harness's timeline: what the user sees, as it changes.
        let kind = shown?.kind ?? (readyCard == nil ? "none" : "ready")
        if kind != markedCardKind {
            markedCardKind = kind
            UpdateHarness.mark("card." + kind)
        }
        #endif
        guard let after = shown?.presentation(version: identity.shortVersion, build: identity.build).dismissesAfter else {
            if expiringCard != nil {
                expiringCard = nil
                cardTimer.cancel()
            }
            return
        }
        guard expiringCard != shown else { return }
        expiringCard = shown
        cardTimer.schedule(after: after) { @MainActor [weak self] in
            guard let self, self.card == self.expiringCard else { return }
            self.expiringCard = nil
            self.dismissIndicatorNote()
        }
    }

    /// The x's tooltip and VoiceOver label.
    public static var cardDismissLabel: String { UpdaterStrings.noticeDismiss }
}
