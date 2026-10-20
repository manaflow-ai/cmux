import Foundation

/// Picks which remote machine serves a browser URL addressed to a machine's
/// private address.
///
/// SSH machines all use this Mac's loopback as their private address, so a
/// loopback URL routes only to the machine that owns the browser.
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
        guard let host else { return nil }
        let target = normalized(host)
        guard !target.isEmpty else { return nil }
        let candidates = addresses.compactMap { normalized($0.value) == target ? $0.key : nil }
        if let owner, candidates.contains(owner) { return owner }
        if PrivateNetworkHostPolicy().isLoopback(host: target) { return nil }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func normalized(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: ["[", "]"]).lowercased()
    }
}
