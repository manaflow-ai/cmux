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

    /// Creates an ordered Iroh dial plan inside the core policy implementation.
    ///
    /// This initializer is intentionally internal. Public callers must use the
    /// validating initializer below or ``directOnly(pinnedPaths:)`` so a private
    /// hint cannot be represented in the public phase by construction.
    init(
        publicPaths: [CmxIrohPathHint],
        privateFallbackPaths: [CmxIrohPathHint]
    ) {
        self.publicPaths = publicPaths
        self.privateFallbackPaths = privateFallbackPaths
    }

    /// Creates a plan after validating its phase boundaries.
    ///
    /// Public phases may contain only public-internet hints. Private and local
    /// hints are accepted only in the fallback phase, which guarantees that an
    /// automatic dial cannot attempt a private address before its public phase
    /// has failed. The explicit ``directOnly(pinnedPaths:)`` constructor is the
    /// sole public exception because it represents a deliberate single-phase
    /// user allowlist.
    /// - Parameters:
    ///   - publicPaths: Native direct/relay hints attempted first.
    ///   - privateFallbackPaths: Profile-authorized private hints attempted
    ///     only after the public phase fails.
    /// - Throws: ``CmxIrohDialPlanError`` when a hint is placed in the wrong
    ///   phase.
    public init(
        validatingPublicPaths publicPaths: [CmxIrohPathHint],
        privateFallbackPaths: [CmxIrohPathHint]
    ) throws {
        if publicPaths.contains(where: { $0.privacyScope != .publicInternet }) {
            throw CmxIrohDialPlanError.privateHintInPublicPhase
        }
        if privateFallbackPaths.contains(where: { $0.privacyScope == .publicInternet }) {
            throw CmxIrohDialPlanError.publicHintInPrivatePhase
        }
        self.init(
            publicPaths: publicPaths,
            privateFallbackPaths: privateFallbackPaths
        )
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

/// Errors raised when a public dial plan places a hint in the wrong phase.
public enum CmxIrohDialPlanError: Error, Equatable, Sendable {
    /// A private or local hint was placed in the first/public phase.
    case privateHintInPublicPhase
    /// A public-internet hint was placed in the private fallback phase.
    case publicHintInPrivatePhase
}
