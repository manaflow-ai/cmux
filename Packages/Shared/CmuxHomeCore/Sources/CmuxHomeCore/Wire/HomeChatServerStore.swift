public import Foundation

/// Persists which chat server Home uses (Settings > Chat Server): hosted by
/// default, or a self-hosted tailnet URL. Backed by the `UserDefaults` it is
/// given (tests pass a suite of their own).
///
/// ```swift
/// let servers = HomeChatServerStore(defaults: .standard)
/// try servers.save(.selfHosted(HomeChatServer.selfHostedURL("mini.tail1234.ts.net")))
/// servers.load() // .selfHosted(http://mini.tail1234.ts.net:7320)
/// ```
public struct HomeChatServerStore {
    /// The defaults key (`home.server`, as in cmux.json on the Mac).
    public static let key = "home.server"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The saved choice; hosted when none is saved or the saved one is no
    /// longer accepted (a self-hosted URL off the tailnet never loads).
    public func load() -> HomeChatServer {
        guard let data = defaults.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode(HomeChatServer.self, from: data) else { return .hosted }
        if case .selfHosted(let url) = saved {
            guard let checked = try? HomeChatServer.selfHostedURL(url.absoluteString) else { return .hosted }
            return .selfHosted(checked)
        }
        return saved
    }

    /// Saves `server`; hosted removes the key.
    public func save(_ server: HomeChatServer) {
        switch server {
        case .hosted:
            defaults.removeObject(forKey: Self.key)
        case .selfHosted:
            defaults.set(try? JSONEncoder().encode(server), forKey: Self.key)
        }
    }
}
