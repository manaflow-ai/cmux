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

    /// The exclusive plan for the per-Computer Direct connection method.
    ///
    /// The user-enabled addresses are the COMPLETE allowlist and form the
    /// single unconditional attempt; no relay path may enter and no fallback
    /// leg exists, so an unreachable allowlist fails the dial instead of
    /// substituting another path. Only socket-address hints are accepted,
    /// preserving this type's guarantee that a relay cannot ride the plan
    /// unreviewed. Returns `nil` for an empty or non-address hint set.
    public static func directOnly(
        pinnedPaths: [CmxIrohPathHint]
    ) -> Self? {
        guard !pinnedPaths.isEmpty,
              pinnedPaths.allSatisfy({ $0.kind == .directAddress }) else {
            return nil
        }
        return Self(publicPaths: pinnedPaths, privateFallbackPaths: [])
    }
}
