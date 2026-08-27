import Foundation

/// Supplies an authenticated local Tailscale control-plane status snapshot.
protocol TailscaleStatusProviding: Sendable {
    func statusJSON() async throws -> Data
}
