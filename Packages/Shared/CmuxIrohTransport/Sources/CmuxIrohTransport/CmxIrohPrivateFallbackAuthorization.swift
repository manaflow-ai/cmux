public import CMUXMobileCore
public import Foundation

/// The exact path generation and private hints admitted for one fallback dial.
public struct CmxIrohPrivateFallbackAuthorization: Equatable, Sendable {
    /// The path generation in which these hints were admitted.
    public let networkPathSnapshot: CmxIrohNetworkPathSnapshot

    /// The exact fallback-only hints admitted in that generation.
    public let pathHints: [CmxIrohPathHint]

    /// The local policy clock used to check hint freshness at admission.
    public let admittedAt: Date

    /// Creates an authorization only for current hints on active profiles.
    ///
    /// - Throws: ``CmxIrohPrivateFallbackValidationError/authorizationMismatch``
    ///   when a hint is public, stale, malformed, or outside the snapshot.
    public init(
        networkPathSnapshot: CmxIrohNetworkPathSnapshot,
        pathHints: [CmxIrohPathHint],
        admittedAt: Date
    ) throws {
        guard !pathHints.isEmpty,
              pathHints.allSatisfy({ hint in
                  guard hint.privacyScope != .publicInternet,
                        hint.isUsable(at: admittedAt),
                        let profile = hint.networkProfile else {
                      return false
                  }
                  return networkPathSnapshot.activeNetworkProfiles.contains(profile)
              }) else {
            throw CmxIrohPrivateFallbackValidationError.authorizationMismatch
        }
        self.networkPathSnapshot = networkPathSnapshot
        self.pathHints = pathHints
        self.admittedAt = admittedAt
    }
}
