public import CMUXMobileCore

/// The current signed authorization and route tiers for one Iroh dial.
public struct CmxIrohClientContext: Equatable, Sendable {
    /// Public paths followed by profile-gated private fallback paths.
    public let dialPlan: CmxIrohDialPlan

    /// The admission proof bound to the exact local and remote endpoints.
    public let credential: CmxIrohAdmissionCredential

    /// The generation-bound authorization for explicit private fallback hints.
    public let privateFallbackAuthorization: CmxIrohPrivateFallbackAuthorization?

    /// Creates a client dial context.
    ///
    /// - Parameters:
    ///   - dialPlan: The explicit two-phase reachability plan.
    ///   - credential: The signed grant or offline pairing proof.
    ///   - privateFallbackAuthorization: The local generation snapshot that
    ///     admitted the plan's private hints, or `nil` for a public-only plan.
    public init(
        dialPlan: CmxIrohDialPlan,
        credential: CmxIrohAdmissionCredential,
        privateFallbackAuthorization: CmxIrohPrivateFallbackAuthorization? = nil
    ) {
        self.dialPlan = dialPlan
        self.credential = credential
        self.privateFallbackAuthorization = privateFallbackAuthorization
    }
}
