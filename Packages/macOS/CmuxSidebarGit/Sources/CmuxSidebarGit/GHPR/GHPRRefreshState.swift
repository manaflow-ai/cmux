public import Foundation

/// Stable, user-presentable categories for the latest GHPR refresh failure.
public enum GHPRRefreshErrorKind: Equatable, Sendable {
    case socketUnavailable
    case incompatibleResponse
    case requestFailed
}

/// Observable refresh state mirrored by the app composition root.
public struct GHPRRefreshState: Equatable, Sendable {
    public var isRefreshing: Bool
    public var lastUpdated: Date?
    public var error: GHPRRefreshErrorKind?

    public init(isRefreshing: Bool = false, lastUpdated: Date? = nil, error: GHPRRefreshErrorKind? = nil) {
        self.isRefreshing = isRefreshing
        self.lastUpdated = lastUpdated
        self.error = error
    }
}
