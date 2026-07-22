public import Foundation

/// A typed toolbar action change emitted by one profile runtime.
public struct BrowserWebExtensionActionUpdate: Equatable, Sendable {
    /// The profile whose extension changed.
    public let profileID: UUID

    /// The associated browser panel, or `nil` for a profile-wide change.
    public let panelID: UUID?

    /// The new immutable action presentation value, when available.
    public let item: BrowserWebExtensionPresentationItem?

    /// Creates a typed toolbar action update.
    ///
    /// - Parameters:
    ///   - profileID: The profile whose extension changed.
    ///   - panelID: The associated browser panel, if any.
    ///   - item: The new action presentation value, if any.
    public init(
        profileID: UUID,
        panelID: UUID?,
        item: BrowserWebExtensionPresentationItem?
    ) {
        self.profileID = profileID
        self.panelID = panelID
        self.item = item
    }
}
