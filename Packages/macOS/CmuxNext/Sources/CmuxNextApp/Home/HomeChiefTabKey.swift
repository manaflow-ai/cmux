import Foundation

/// The idempotency key of one chief tab creation (`origin` + `mutation_id`
/// of `new-conversation-tab`). A retry after a lost reply reuses the key, so
/// the store replays the first tab. Once the chief tab is seen, or the store
/// refuses the key because its tab closed, the next creation takes a new
/// key: the store never re-creates a closed chief tab under its old browser
/// id (one browser id belongs to at most one tab).
struct HomeChiefTabKey {
    /// The daemon's refusal of a key whose tab was closed.
    static let keyClosedCode = "frontend_browser_key_closed"

    private var pending: String?
    private let make: @Sendable () -> String

    init(make: @escaping @Sendable () -> String = { "home-chief-tab-\(UUID().uuidString.lowercased())" }) {
        self.make = make
    }

    /// The key of the next creation: the pending one, else a new one.
    mutating func forCreate() -> String {
        if let pending { return pending }
        let key = make()
        pending = key
        return key
    }

    /// The chief tab is present, or the store refused the key because its tab closed.
    mutating func settle() { pending = nil }
}
