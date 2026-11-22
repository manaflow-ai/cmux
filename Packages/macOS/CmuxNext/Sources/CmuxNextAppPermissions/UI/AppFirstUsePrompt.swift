import Foundation

/// The input of the inline first-use prompt: which app asks for which
/// optional scope, and where the answer goes (the App sends it as
/// `AppGrantChange.answerFirstUse` and releases or refuses the waiting call).
public struct AppFirstUsePrompt {
    public var listing: AppPermissionsListing
    public var scope: String
    public var answer: @MainActor (AppFirstUseAnswer) -> Void

    public init(listing: AppPermissionsListing, scope: String, answer: @escaping @MainActor (AppFirstUseAnswer) -> Void) {
        self.listing = listing
        self.scope = scope
        self.answer = answer
    }

    /// The manifest's reason for the scope.
    public var reason: String { listing.reason(for: scope) }
}

/// A workspace, room or machine the reach selectors can name.
public nonisolated struct AppResourceOption: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
