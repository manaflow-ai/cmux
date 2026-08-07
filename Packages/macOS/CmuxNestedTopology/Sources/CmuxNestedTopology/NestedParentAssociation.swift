/// Resolved, topology-bearing parentage and heuristic state for a provider-owned pane.
public struct NestedParentAssociation: Codable, Equatable, Sendable {
    /// Pane/session generation to which the association applies.
    public let key: NestedAssociationKey

    /// Provider-owned parent tab used for hierarchy, focus, and close cascades.
    public let tabID: NestedNodeID

    /// Source of the resolved parent relationship.
    public let authority: NestedAssociationAuthority

    /// Whether a successful heuristic has already consumed its one attempt.
    public let heuristicAlreadySatisfied: Bool

    /// Creates a resolved parent association.
    ///
    /// - Parameters:
    ///   - key: Pane/session generation to associate.
    ///   - tabID: Resolved provider-owned parent tab.
    ///   - authority: Source of the parent relationship.
    ///   - heuristicAlreadySatisfied: Whether a successful heuristic is locked.
    public init(
        key: NestedAssociationKey,
        tabID: NestedNodeID,
        authority: NestedAssociationAuthority,
        heuristicAlreadySatisfied: Bool
    ) {
        self.key = key
        self.tabID = tabID
        self.authority = authority
        self.heuristicAlreadySatisfied = heuristicAlreadySatisfied
    }

    func replacing(with candidate: NestedParentAssociation) -> NestedParentAssociation {
        guard candidate.key == key else {
            guard authority == .provider, candidate.authority == .heuristic else {
                return candidate
            }
            // A session generation resets its heuristic lock, not provider-owned parentage.
            return NestedParentAssociation(
                key: candidate.key,
                tabID: tabID,
                authority: .provider,
                heuristicAlreadySatisfied: false
            )
        }

        switch candidate.authority {
        case .provider:
            return NestedParentAssociation(
                key: candidate.key,
                tabID: candidate.tabID,
                authority: .provider,
                heuristicAlreadySatisfied: heuristicAlreadySatisfied
                    || candidate.heuristicAlreadySatisfied
            )
        case .heuristic:
            guard !rejectsRepeatedHeuristic(candidate) else { return self }
            return candidate
        }
    }

    /// Whether a same-key heuristic candidate has already lost parent authority.
    func rejectsRepeatedHeuristic(_ candidate: NestedParentAssociation) -> Bool {
        candidate.key == key
            && candidate.authority == .heuristic
            && (authority == .provider || heuristicAlreadySatisfied)
    }
}
