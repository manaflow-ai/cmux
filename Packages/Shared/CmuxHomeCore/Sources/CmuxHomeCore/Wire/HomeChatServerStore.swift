public import Foundation

/// Persists which chat server Home uses (not implemented yet: always hosted).
public struct HomeChatServerStore: Sendable {
    /// The defaults key (`home.server`, as in cmux.json on the Mac).
    public static let key = "home.server"

    public init(defaults: UserDefaults) {}

    public func load() -> HomeChatServer { .hosted }

    public func save(_ server: HomeChatServer) {}
}
