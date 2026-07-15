public import Foundation

/// Redacted relay policy state suitable for UI and support diagnostics.
public struct CmxIrohRelayDiagnosticsSnapshot: Equatable, Sendable {
    /// Active policy source and availability.
    public let source: CmxIrohRelayPolicySource

    /// Signed policy identifier, when a managed policy is active.
    public let policyID: String?

    /// Signed policy sequence, when a managed policy is active.
    public let policySequence: Int64?

    /// Signed policy expiry, when a managed policy is active.
    public let policyExpiresAt: Date?

    /// Current account preference revision.
    public let preferenceRevision: Int64?

    /// Stable IDs selected from the managed policy.
    public let selectedRelayIDs: [String]

    /// Exact relay origins currently allowed by the endpoint.
    public let selectedRelayURLs: [String]

    /// Requested managed IDs missing from the signed policy.
    public let staleRelayIDs: [String]

    /// Custom relay IDs lacking a required device-local token.
    public let missingCredentialRelayIDs: [String]

    /// Last non-secret policy resolution failure.
    public let failure: CmxIrohRelayPolicyFailure?

    static let inactive = CmxIrohRelayDiagnosticsSnapshot(
        source: .inactive,
        policyID: nil,
        policySequence: nil,
        policyExpiresAt: nil,
        preferenceRevision: nil,
        selectedRelayIDs: [],
        selectedRelayURLs: [],
        staleRelayIDs: [],
        missingCredentialRelayIDs: [],
        failure: nil
    )
}
