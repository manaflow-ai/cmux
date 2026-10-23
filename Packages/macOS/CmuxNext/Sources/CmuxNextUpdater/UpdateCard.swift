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
    /// The running build was pulled off the feed (``PulledBuildWatch``): why, and the kept
    /// build's version when a rollback to it would run.
    case pulled(reason: String, rollbackVersion: String?)
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
    /// A pulled build: roll back to the kept build.
    case rollBack = "roll_back"
    /// A pulled build: keep it until the fix installs (the default).
    case waitForFix = "wait_for_fix"
    /// An install the relaunch gate holds: relaunch now anyway.
    case relaunchNow = "relaunch_now"

    public var title: String {
        switch self {
        case .update: UpdaterStrings.update
        case .releaseNotes: UpdaterStrings.releaseNotes
        case .retry: UpdaterStrings.retry
        case .details: UpdaterStrings.details
        case .rollBack: UpdaterStrings.pulledRollBack
        case .waitForFix: UpdaterStrings.pulledWait
        case .relaunchNow: UpdaterStrings.relaunch
        }
    }

    /// The call to action (filled); the others are quiet.
    public var isProminent: Bool { self == .update || self == .waitForFix }
}
