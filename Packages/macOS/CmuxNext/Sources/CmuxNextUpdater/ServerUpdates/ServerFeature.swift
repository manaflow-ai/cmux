import Foundation

/// A user-visible feature that one server capability turns on.
public nonisolated struct ServerFeature: Sendable, Equatable, Hashable {
    /// The capability the server advertises (`tab-groups-v1`).
    public var capability: String
    /// The feature's short localized name ("Tab groups").
    public var title: String

    /// - Parameters:
    ///   - capability: The advertised capability name.
    ///   - title: The localized feature name.
    public init(capability: String, title: String) {
        self.capability = capability
        self.title = title
    }
}
