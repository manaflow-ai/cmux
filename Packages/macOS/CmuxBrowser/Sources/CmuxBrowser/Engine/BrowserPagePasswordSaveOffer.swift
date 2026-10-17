public import Foundation

/// An engine's offer to save or update the password of a sign-in the page
/// just submitted (Chromium's password manager). Only the site and the user
/// name cross into the app; the password stays inside the engine from the
/// form to its store.
public struct BrowserPagePasswordSaveOffer: Equatable, Sendable {
    /// The engine's id for the offer, unique per page while it waits.
    public let id: Int
    /// The signed-in site.
    public let origin: URL
    /// The submitted user name; empty when the form had none.
    public let username: String
    /// `true` when the site has this sign-in saved with another password.
    public let isUpdate: Bool

    public init(id: Int, origin: URL, username: String, isUpdate: Bool) {
        self.id = id
        self.origin = origin
        self.username = username
        self.isUpdate = isUpdate
    }
}

/// The person's answer to a ``BrowserPagePasswordSaveOffer``.
public enum BrowserPagePasswordSaveAnswer: Equatable, Sendable {
    /// Save (or update) the password.
    case save
    /// Never offer to save a password for this site again.
    case never
    /// Not this time.
    case notNow
}

/// Implemented by a page's UI delegate (the browser panel) for engines with
/// a password manager. An engine checks for it; without it, every offer is
/// declined (``BrowserPagePasswordSaveAnswer/notNow``).
@MainActor
public protocol BrowserPagePasswordPromptDelegate: AnyObject {
    /// Asks whether to save a submitted sign-in's password.
    /// - Returns: The answer, or `nil` when the question ended unanswered
    ///   (the engine dropped it, the panel closed).
    func page(_ page: any BrowserPage, offerToSavePassword offer: BrowserPagePasswordSaveOffer) async -> BrowserPagePasswordSaveAnswer?

    /// The engine dropped an offer it made (the tab navigated on or closed):
    /// its question goes away unanswered.
    func page(_ page: any BrowserPage, didEndPasswordSaveOffer id: Int)
}
