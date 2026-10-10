import CmuxNextWakeups
import CmuxUpdater
public import Foundation

/// The update status on the sidebar's shared notice card (Lawrence
/// 2026-10-09): its content for this build, its buttons, its x, and the up
/// to date notice hiding itself on the injected clock.
extension UpdaterService {
    /// How long "up to date" stays before it hides itself.
    nonisolated public static var noteDuration: Duration { UpdateCard.upToDateDuration }

    /// The card's icon, text and actions for the running build, or nil.
    public var cardPresentation: UpdateCardPresentation? {
        card?.presentation(version: identity.shortVersion, build: identity.build)
    }

    /// The found update's release notes: its GitHub release or commit, else
    /// the releases page; nil without a found update.
    public var cardReleaseNotesURL: URL? {
        let version: String?
        switch card {
        case .available(let found): version = found
        case .note(.found(let found)): version = found
        case .checking, .downloading, .note, nil: return nil
        }
        return version.flatMap { UpdateState.ReleaseNotes(displayVersionString: $0)?.url }
            ?? URL(string: "https://github.com/manaflow-ai/cmux/releases")
    }

    /// A notice button. Release Notes is a link the App opens
    /// (``cardReleaseNotesURL``); the others act here.
    public func performCardAction(_ action: UpdateCardAction) {
        switch action {
        case .update: installClicked()
        case .retry: checkForUpdates()
        case .details: presentUpdateUI?()
        case .releaseNotes: break
        }
    }

    /// The notice's x: a found update hides until a newer one; a result
    /// clears (as when it times out).
    public func dismissCard() {
        switch card {
        case .available(let version):
            dismissedAvailableVersion = version ?? ""
        case .note:
            dismissIndicatorNote()
        case .checking, .downloading, nil:
            break
        }
        followCardExpiry()
    }

    /// Schedules the shown card's timeout (up to date), once per card, or
    /// cancels it when the card changed to one that waits.
    func followCardExpiry() {
        let shown = card
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
