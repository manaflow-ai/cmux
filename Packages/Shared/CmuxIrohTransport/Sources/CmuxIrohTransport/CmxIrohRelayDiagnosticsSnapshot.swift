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

    /// Stable relay IDs selected from the active preference.
    public let selectedRelayIDs: [String]

    /// Number of relay origins currently allowed by the endpoint.
    public let selectedRelayCount: Int

    /// Requested managed IDs missing from the signed policy.
    public let staleRelayIDs: [String]

    /// Custom relay IDs lacking a required device-local token.
    public let missingCredentialRelayIDs: [String]

    /// Last non-secret policy resolution failure.
    public let failure: CmxIrohRelayPolicyFailure?

    /// Start of the current run of consecutive policy refresh failures, `nil`
    /// while the last refresh succeeded. A host whose refresh keeps failing
    /// must be visibly degraded instead of silently unreachable
    /// (cmux#10873); consumers treat the state as persistent once
    /// ``consecutiveRefreshFailures`` reaches
    /// ``CmxIrohRelayPolicyService/persistentRefreshFailureThreshold``.
    public let refreshFailingSince: Date?

    /// Length of the current run of consecutive policy refresh failures.
    public let consecutiveRefreshFailures: Int

    init(
        source: CmxIrohRelayPolicySource,
        policyID: String?,
        policySequence: Int64?,
        policyExpiresAt: Date?,
        preferenceRevision: Int64?,
        selectedRelayIDs: [String],
        selectedRelayCount: Int,
        staleRelayIDs: [String],
        missingCredentialRelayIDs: [String],
        failure: CmxIrohRelayPolicyFailure?,
        refreshFailingSince: Date? = nil,
        consecutiveRefreshFailures: Int = 0
    ) {
        self.source = source
        self.policyID = policyID
        self.policySequence = policySequence
        self.policyExpiresAt = policyExpiresAt
        self.preferenceRevision = preferenceRevision
        self.selectedRelayIDs = selectedRelayIDs
        self.selectedRelayCount = selectedRelayCount
        self.staleRelayIDs = staleRelayIDs
        self.missingCredentialRelayIDs = missingCredentialRelayIDs
        self.failure = failure
        self.refreshFailingSince = refreshFailingSince
        self.consecutiveRefreshFailures = consecutiveRefreshFailures
    }

    /// The same snapshot restamped with the current refresh failure streak.
    func withRefreshFailureStreak(
        since: Date?,
        count: Int
    ) -> CmxIrohRelayDiagnosticsSnapshot {
        CmxIrohRelayDiagnosticsSnapshot(
            source: source,
            policyID: policyID,
            policySequence: policySequence,
            policyExpiresAt: policyExpiresAt,
            preferenceRevision: preferenceRevision,
            selectedRelayIDs: selectedRelayIDs,
            selectedRelayCount: selectedRelayCount,
            staleRelayIDs: staleRelayIDs,
            missingCredentialRelayIDs: missingCredentialRelayIDs,
            failure: failure,
            refreshFailingSince: since,
            consecutiveRefreshFailures: count
        )
    }

    static let inactive = CmxIrohRelayDiagnosticsSnapshot(
        source: .inactive,
        policyID: nil,
        policySequence: nil,
        policyExpiresAt: nil,
        preferenceRevision: nil,
        selectedRelayIDs: [],
        selectedRelayCount: 0,
        staleRelayIDs: [],
        missingCredentialRelayIDs: [],
        failure: nil
    )
}
