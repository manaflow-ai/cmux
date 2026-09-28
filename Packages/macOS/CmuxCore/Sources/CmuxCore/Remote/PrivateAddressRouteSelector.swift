import Foundation

/// Picks which remote machine serves a browser URL addressed to a machine's
/// private address.
public struct PrivateAddressRouteSelector<Machine: Hashable & Sendable>: Sendable {
    /// Creates the selector.
    public init() {}

    /// The machine that serves `host`, or `nil` when the URL must not be
    /// routed to any remote machine.
    ///
    /// - Parameters:
    ///   - host: The URL host.
    ///   - owner: The machine the browser belongs to, if any.
    ///   - addresses: Each connected machine's private address.
    public func machine(forHost host: String?, owner: Machine?, addresses: [Machine: String]) -> Machine? {
        addresses.first { $0.value.trimmingCharacters(in: ["[", "]"]) == host?.trimmingCharacters(in: ["[", "]"]) }?.key
    }
}
