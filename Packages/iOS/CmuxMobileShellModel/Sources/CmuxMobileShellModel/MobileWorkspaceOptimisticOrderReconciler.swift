import Foundation

/// Decides whether an optimistic workspace order should remain visible.
public struct MobileWorkspaceOptimisticOrderReconciler {
    /// Returns whether the UI should keep displaying the optimistic order.
    ///
    /// Successful move replies can arrive before the authoritative workspace
    /// snapshot. In that window, clearing optimistic state makes the list snap
    /// back to the stale order and then forward again when the snapshot lands.
    /// This helper keeps the optimistic order until an authoritative snapshot
    /// either matches it or clearly supersedes the previous authoritative order.
    ///
    /// - Parameters:
    ///   - optimistic: The predicted order currently displayed by the UI.
    ///   - authoritative: The latest authoritative snapshot.
    ///   - previousAuthoritative: The authoritative snapshot the optimistic
    ///     order was based on. Pass `nil` when the caller has no prior snapshot.
    ///   - moveIsPending: Whether the request is still in flight.
    ///   - moveDidFail: Whether the request failed and should roll back.
    /// - Returns: `true` to keep the optimistic order, `false` to adopt the
    ///   authoritative order.
    public static func shouldKeepOptimisticOrder(
        optimistic: [MobileWorkspacePreview]?,
        authoritative: [MobileWorkspacePreview],
        previousAuthoritative: [MobileWorkspacePreview]?,
        moveIsPending: Bool,
        moveDidFail: Bool = false
    ) -> Bool {
        guard let optimistic else { return false }
        guard !moveDidFail else { return false }
        let optimisticSignature = signature(optimistic)
        let authoritativeSignature = signature(authoritative)
        if optimisticSignature == authoritativeSignature {
            return false
        }
        if moveIsPending {
            guard let previousAuthoritative else { return true }
            return authoritativeSignature == signature(previousAuthoritative)
        }
        guard let previousAuthoritative else { return false }
        return authoritativeSignature == signature(previousAuthoritative)
    }

    /// Returns the stable order signature for reconciliation.
    /// - Parameter workspaces: The workspace snapshot to compare.
    /// - Returns: A signature that ignores live row content.
    public static func signature(
        _ workspaces: [MobileWorkspacePreview]
    ) -> [MobileWorkspaceOrderSignature] {
        workspaces.map {
            MobileWorkspaceOrderSignature(id: $0.id, groupID: $0.groupID, isPinned: $0.isPinned)
        }
    }
}
