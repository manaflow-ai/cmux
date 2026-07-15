/// Immutable metadata for the workspace's phone-local browser card.
public struct PaneLocalBrowserCardSnapshot: Equatable, Identifiable, Sendable {
    /// The phone-local browser surface identifier.
    public let id: String
    /// The current page title or localized browser fallback.
    public let title: String

    /// Creates one phone-local browser card input.
    /// - Parameters:
    ///   - id: The browser surface identifier.
    ///   - title: The current page title.
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}
