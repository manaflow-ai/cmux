import Foundation

/// The update status the sidebar's notice card shows (Lawrence 2026-10-09:
/// the shared card for messages to the user, one model for every state).
/// A check the user asked for shows its progress and result; a found update
/// that waits for a click (`updates.downloadAutomatically` off) shows
/// without a check. A staged or installing update is never this card: the
/// staged update card owns it (UPDATE-CARD).
nonisolated public enum UpdateCard: Equatable, Sendable {
    /// The user asked to check.
    case checking
    /// The user asked and a found update downloads.
    case downloading(progress: Double?)
    /// Found, not downloaded: Update downloads, installs and relaunches.
    case available(version: String?)
    /// The result of a check the user asked for.
    case note(UpdateNote)
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

    public var title: String {
        switch self {
        case .update: UpdaterStrings.update
        case .releaseNotes: UpdaterStrings.releaseNotes
        case .retry: UpdaterStrings.retry
        case .details: UpdaterStrings.details
        }
    }

    /// The call to action (filled); the others are quiet.
    public var isProminent: Bool { self == .update }
}
