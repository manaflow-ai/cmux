public import CMUXMobileCore

/// The current signed authorization and route tiers for one Iroh dial.
public struct CmxIrohClientContext: Equatable, Sendable {
    /// The policy captured for the physical dial that consumes this context.
    /// Keeping it beside the two-phase plan prevents a late fallback provider
    /// from losing the user's hard transport constraint.
    public let transportMode: CmxTransportMode
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
    ///   - transportMode: The hard route-class policy captured for this dial.
    public init(
        dialPlan: CmxIrohDialPlan,
        credential: CmxIrohAdmissionCredential,
        privateFallbackAuthorization: CmxIrohPrivateFallbackAuthorization? = nil,
        transportMode: CmxTransportMode = .automatic
    ) {
        self.transportMode = transportMode
        self.dialPlan = dialPlan
        self.credential = credential
        self.privateFallbackAuthorization = privateFallbackAuthorization
    }
}
