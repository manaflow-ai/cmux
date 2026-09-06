import Foundation

/// Produces the completed wg-quick config for this Mac, enrolling it with the
/// control plane if needed. ``VMTunnelEnroller`` is the real implementation
/// over ``VMTunnelManager``; tests use a fake.
protocol CloudTunnelEnrolling: Sendable {
    func enroll() async throws -> CloudTunnelEnrollment
}

/// The result of enrollment: everything the VPN configuration needs.
