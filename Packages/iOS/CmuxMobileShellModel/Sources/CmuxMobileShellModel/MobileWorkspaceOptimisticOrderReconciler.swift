import Foundation

/// Reconciles a pipelined optimistic workspace order with host snapshots.
///
/// Successful move replies can arrive before the authoritative workspace
/// snapshot. In that window, clearing optimistic state makes the list snap
/// back. Every move therefore records its source order. A snapshot matching
/// any recorded intermediate keeps the displayed prediction and prunes older
/// intermediates; the displayed prediction drains the chain, while any other
/// order supersedes it. A failed move always clears the complete chain.
public struct MobileWorkspaceOptimisticOrderReconciler {
    /// The ID/membership order currently displayed by the UI.
    public let optimisticOrder: MobileWorkspaceOptimisticOrder?
    /// Source orders for the outstanding serialized move chain.
    public let pendingBases: [MobileWorkspaceOptimisticOrder]

    /// Creates optimistic reconciliation state.
    /// - Parameters:
    ///   - optimisticOrder: The order currently displayed, if any.
    ///   - pendingBases: Source orders for all outstanding moves, oldest first.
    public init(
        optimisticOrder: MobileWorkspaceOptimisticOrder? = nil,
        pendingBases: [MobileWorkspaceOptimisticOrder] = []
    ) {
        self.optimisticOrder = optimisticOrder
        self.pendingBases = pendingBases
    }

    /// Returns the next reconciliation state for an authoritative snapshot.
    /// - Parameters:
    ///   - authoritative: The latest host workspace snapshot.
    ///   - groups: The current groups, for pin-tier staleness checks.
    ///   - moveDidFail: Whether any move in the dependent chain failed.
    public func reconciling(
        authoritative: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview] = [],
        moveDidFail: Bool = false
    ) -> MobileWorkspaceOptimisticOrderReconciler {
        guard !moveDidFail, let optimisticOrder else { return .init() }
        guard !optimisticOrder.matches(authoritative: authoritative, groups: groups) else { return .init() }
        guard let matchedIndex = pendingBases.firstIndex(where: {
            $0.matches(authoritative: authoritative, groups: groups)
        }) else {
            return .init()
        }
        // Keep the matched order because it is the source of the next
        // outstanding move; only strictly older snapshots are now obsolete.
        return .init(
            optimisticOrder: optimisticOrder,
            pendingBases: Array(pendingBases[matchedIndex...])
        )
    }
}
