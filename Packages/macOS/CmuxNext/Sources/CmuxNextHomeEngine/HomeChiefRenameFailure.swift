import Foundation

/// Why renaming a Chief from its settings card did not take; the card names the reason.
///
/// The app's ``HomeChiefSettingsView/onRename`` returns one of these, or nil when the new name
/// was saved. A Chief of this Mac renames through the daemon; a cloud Chief renames its record
/// on the signed-in account (`chief.update {display_name}`).
public enum HomeChiefRenameFailure: Hashable, Sendable {
    /// Nothing answered: no daemon for a Chief of this Mac, or the account's server is offline.
    case noConnection
    /// The cloud Chief belongs to an account this Mac is not signed in to now.
    case signedOut
    /// Another device changed the Chief at the same time, and a fresh read did not settle it.
    case changedElsewhere
    /// The name is refused: 1 to 100 characters, without control characters.
    case invalidName
    /// The account does not list this Chief (archived, or removed on another device).
    case notFound
    /// The owner refused for another reason; the associated value is its code or message.
    case refused(String)
}
