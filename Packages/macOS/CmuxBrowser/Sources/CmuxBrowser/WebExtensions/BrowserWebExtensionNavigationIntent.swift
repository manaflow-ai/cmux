public import Foundation

/// Describes a navigation waiting on one profile's extension readiness decision.
public struct BrowserWebExtensionNavigationIntent: Identifiable, Equatable, Sendable {
    /// A stable identifier used for cancellation and exactly-once release.
    public let id: UUID

    /// The browser profile that owns the navigation.
    public let profileID: UUID

    /// The destination used for diagnostics without retaining executable-owned state.
    public let targetURL: URL?

    /// The lifecycle path that submitted the navigation.
    public let reason: BrowserWebExtensionNavigationReason

    /// Creates a profile-owned navigation intent.
    ///
    /// - Parameters:
    ///   - id: A stable cancellation identifier.
    ///   - profileID: The browser profile that owns the navigation.
    ///   - targetURL: The intended destination, when available.
    ///   - reason: The lifecycle path that submitted the navigation.
    public init(
        id: UUID = UUID(),
        profileID: UUID,
        targetURL: URL?,
        reason: BrowserWebExtensionNavigationReason
    ) {
        self.id = id
        self.profileID = profileID
        self.targetURL = targetURL
        self.reason = reason
    }
}
