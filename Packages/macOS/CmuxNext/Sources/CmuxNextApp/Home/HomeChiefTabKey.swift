import Foundation

/// The idempotency key of one chief tab creation (`origin` + `mutation_id`
/// of `new-conversation-tab`).
struct HomeChiefTabKey {
    init(make: @escaping @Sendable () -> String = { "home-chief-tab" }) {}

    /// The key of the next creation.
    mutating func forCreate() -> String { "home-chief-tab" }

    /// The chief tab is present, or the store refused the key because its tab closed.
    mutating func settle() {}
}
