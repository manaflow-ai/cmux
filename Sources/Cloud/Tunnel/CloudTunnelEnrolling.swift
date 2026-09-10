import Foundation

/// Produces the completed wg-quick config for this Mac, enrolling it with the
/// control plane if needed. ``VMTunnelEnroller`` is the real implementation
/// over ``VMTunnelManager``; tests use a fake.
protocol CloudTunnelEnrolling: Sendable {
    func enroll() async throws -> CloudTunnelEnrollment

    /// Forget an enrollment the policy refused right after it completed, so
    /// nothing it wrote can make the next launch treat this Mac as configured.
    func discardEnrollment()
}

/// The result of enrollment: everything the VPN configuration needs.
