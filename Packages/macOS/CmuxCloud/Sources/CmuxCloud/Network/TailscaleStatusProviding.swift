import Foundation

/// Supplies an authenticated local Tailscale control-plane status snapshot.
public protocol TailscaleStatusProviding: Sendable {
    func statusJSON() async throws -> Data
}
