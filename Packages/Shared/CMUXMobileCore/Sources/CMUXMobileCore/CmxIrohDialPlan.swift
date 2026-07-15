/// The two ordered attempts for reaching an Iroh peer.
///
/// Callers must finish or cancel the public/native attempt before starting the
/// private-network fallback. The type intentionally has no flattened hint
/// list, so private routes cannot accidentally enter Iroh's first dial.
public struct CmxIrohDialPlan: Equatable, Sendable {
    /// Iroh-native public direct and relay paths used for the first attempt.
    public let publicPaths: [CmxIrohPathHint]
    /// Active-profile private/LAN paths used only after the first attempt fails.
    public let privateFallbackPaths: [CmxIrohPathHint]

    init(
        publicPaths: [CmxIrohPathHint],
        privateFallbackPaths: [CmxIrohPathHint]
    ) {
        self.publicPaths = publicPaths
        self.privateFallbackPaths = privateFallbackPaths
    }
}
