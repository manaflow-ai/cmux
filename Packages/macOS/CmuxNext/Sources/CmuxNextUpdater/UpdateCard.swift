import Foundation

/// The update status the sidebar's notice card shows (Lawrence 2026-10-09:
/// the shared card for messages to the user, one model for every state).
/// A check the user asked for shows its progress and result; a scheduled
/// (background) check shows nothing (Lawrence 2026-10-20). A found update
/// that waits for a click shows without a check only when the person turned
/// `updates.downloadAutomatically` off. A staged update is never this card:
/// the staged update card owns it (UPDATE-CARD), and so does its own
/// install click.
nonisolated public enum UpdateCard: Equatable, Sendable {
    /// The user asked to check.
    case checking
    /// The user asked and a found update downloads, then unpacks.
    case downloading(UpdateTransfer)
    /// Found, not downloaded: Update downloads, installs and relaunches.
    case available(version: String?)
    /// The user asked (Attempt Update, a check that went on to install):
    /// the update installs and cmux relaunches. A click on the staged update
    /// card's Restart to Update keeps that card instead (its button reads
    /// Installing…).
    case installing
    /// The result of a check the user asked for.
    case note(UpdateNote)
    /// Restart to Update found a build newer than the staged one, or the staged or running build
    /// was pulled off the feed: the newest build downloads in its place (`transfer` once its
    /// download runs), with no click (Leo 2026-10-29: "if there's multiple nightlies, i should
    /// only need to do one to get the latest"). `pulled`: the running build was pulled (one line says so).
    case gettingNewest(UpdateTransfer?, pulled: Bool)
}

/// What a notice card's button does. The raw value is the card action id.
nonisolated public enum UpdateCardAction: String, Sendable, CaseIterable {
    /// Download, install and relaunch the found update.
    case update
    /// Open the found update's release notes.
    case releaseNotes = "release_notes"
    /// Check again after a failure.
    case retry
    /// Show a failure's details (the update sheet).
    case details
    /// Stop the running download: Sparkle deletes the partial file and the card goes back to the
    /// found update, whose Update downloads it again (Leo 2026-10-31: "WHY CAN'T I CANCEL THE DOWNLOAD").
    case cancelDownload = "cancel_download"

    public var title: String {
        switch self {
        case .update: UpdaterStrings.update
        case .releaseNotes: UpdaterStrings.releaseNotes
        case .retry: UpdaterStrings.retry
        case .details: UpdaterStrings.details
        case .cancelDownload: UpdaterStrings.cancel
        }
    }

    /// The call to action (filled); the others are quiet.
    public var isProminent: Bool { self == .update }

    /// The SF Symbol of an action drawn as the card's right-hand control (``UpdateCardPresentation/trailing``).
    public var symbol: String {
        switch self {
        case .cancelDownload: "xmark.circle.fill"
        case .update: "arrow.down.circle"
        case .releaseNotes: "doc.text"
        case .retry: "arrow.clockwise"
        case .details: "info.circle"
        }
    }
}
