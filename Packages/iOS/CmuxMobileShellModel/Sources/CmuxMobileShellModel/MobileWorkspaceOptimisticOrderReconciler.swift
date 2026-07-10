import Foundation

/// Decides whether an optimistic workspace order should remain visible.
///
/// Successful move replies can arrive before the authoritative workspace
/// snapshot. In that window, clearing optimistic state makes the list snap
/// back to the stale order and then forward again when the snapshot lands.
/// The reconciler keeps the optimistic order until an authoritative snapshot
/// either matches it or clearly supersedes the previous authoritative order.
public struct MobileWorkspaceOptimisticOrderReconciler {
    /// The predicted order currently displayed by the UI.
    let optimistic: [MobileWorkspacePreview]?
    /// The latest authoritative snapshot.
    let authoritative: [MobileWorkspacePreview]
    /// The snapshot the optimistic order was based on (the prior optimistic
    /// order for pipelined moves). `nil` when the caller has no prior snapshot.
    let previousAuthoritative: [MobileWorkspacePreview]?
    /// Whether the move request is still in flight.
    let moveIsPending: Bool
    /// Whether the move request failed and should roll back.
    let moveDidFail: Bool

    /// Creates a reconciler over one optimistic/authoritative snapshot pair.
    public init(
        optimistic: [MobileWorkspacePreview]?,
        authoritative: [MobileWorkspacePreview],
        previousAuthoritative: [MobileWorkspacePreview]?,
        moveIsPending: Bool,
        moveDidFail: Bool = false
    ) {
        self.optimistic = optimistic
        self.authoritative = authoritative
        self.previousAuthoritative = previousAuthoritative
        self.moveIsPending = moveIsPending
        self.moveDidFail = moveDidFail
    }

    /// Returns `true` to keep the optimistic order, `false` to adopt the
    /// authoritative order.
    public func shouldKeepOptimisticOrder() -> Bool {
        guard let optimistic else { return false }
        guard !moveDidFail else { return false }
        let optimisticSignature = MobileWorkspaceOrderSignature.signature(optimistic)
        let authoritativeSignature = MobileWorkspaceOrderSignature.signature(authoritative)
        if optimisticSignature == authoritativeSignature {
            return false
        }
        if moveIsPending {
            guard let previousAuthoritative else { return true }
            return authoritativeSignature == MobileWorkspaceOrderSignature.signature(previousAuthoritative)
        }
        guard let previousAuthoritative else { return false }
        return authoritativeSignature == MobileWorkspaceOrderSignature.signature(previousAuthoritative)
    }
}
