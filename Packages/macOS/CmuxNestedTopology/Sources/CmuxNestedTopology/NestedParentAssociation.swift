/// Resolved, topology-bearing parentage and heuristic state for a provider-owned pane.
public struct NestedParentAssociation: Codable, Equatable, Sendable {
    /// Caps runtime-only session history so stale events fail closed without unbounded growth.
    private static let maximumSupersededKeys = 32

    /// Pane/session generation to which the association applies.
    public let key: NestedAssociationKey

    /// Provider-owned parent tab used for hierarchy, focus, and close cascades.
    public let tabID: NestedNodeID

    /// Source of the resolved parent relationship.
    public let authority: NestedAssociationAuthority

    /// Whether a successful heuristic has already consumed its one attempt.
    public let heuristicAlreadySatisfied: Bool

    /// Pane/session keys that have already been superseded in this live state.
    private let supersededKeys: [NestedAssociationKey]

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
        self.supersededKeys = []
    }

    func replacing(with candidate: NestedParentAssociation) -> NestedParentAssociation {
        guard candidate.key == key else {
            guard !supersededKeys.contains(candidate.key) else {
                return self
            }
            let nextSupersededKeys = Array(
                (supersededKeys + [key]).suffix(Self.maximumSupersededKeys)
            )
            guard authority == .provider, candidate.authority == .heuristic else {
                return NestedParentAssociation(
                    key: candidate.key,
                    tabID: candidate.tabID,
                    authority: candidate.authority,
                    heuristicAlreadySatisfied: candidate.heuristicAlreadySatisfied,
                    supersededKeys: nextSupersededKeys
                )
            }
            // A session generation resets its heuristic lock, not provider-owned parentage.
            return NestedParentAssociation(
                key: candidate.key,
                tabID: tabID,
                authority: .provider,
                heuristicAlreadySatisfied: false,
                supersededKeys: nextSupersededKeys
            )
        }

        switch candidate.authority {
        case .provider:
            return NestedParentAssociation(
                key: candidate.key,
                tabID: candidate.tabID,
                authority: .provider,
                heuristicAlreadySatisfied: heuristicAlreadySatisfied
                    || candidate.heuristicAlreadySatisfied,
                supersededKeys: supersededKeys
            )
        case .heuristic:
            guard !rejectsRepeatedHeuristic(candidate) else { return self }
            return NestedParentAssociation(
                key: candidate.key,
                tabID: candidate.tabID,
                authority: .heuristic,
                heuristicAlreadySatisfied: candidate.heuristicAlreadySatisfied,
                supersededKeys: supersededKeys
            )
        }
    }

    /// Whether a same-key heuristic candidate has already lost parent authority.
    func rejectsRepeatedHeuristic(_ candidate: NestedParentAssociation) -> Bool {
        candidate.key == key
            && candidate.authority == .heuristic
            && (authority == .provider || authority == .heuristic || heuristicAlreadySatisfied)
    }

    /// Whether a session-key replacement is rejected by the bounded replay guard.
    func rejectsSupersededSession(_ candidate: NestedParentAssociation) -> Bool {
        candidate.key != key
            && supersededKeys.contains(candidate.key)
    }

    private init(
        key: NestedAssociationKey,
        tabID: NestedNodeID,
        authority: NestedAssociationAuthority,
        heuristicAlreadySatisfied: Bool,
        supersededKeys: [NestedAssociationKey]
    ) {
        self.key = key
        self.tabID = tabID
        self.authority = authority
        self.heuristicAlreadySatisfied = heuristicAlreadySatisfied
        self.supersededKeys = supersededKeys
    }

    /// Ignores runtime replay guards so provider content remains idempotent across snapshots.
    public static func == (lhs: NestedParentAssociation, rhs: NestedParentAssociation) -> Bool {
        lhs.key == rhs.key
            && lhs.tabID == rhs.tabID
            && lhs.authority == rhs.authority
            && lhs.heuristicAlreadySatisfied == rhs.heuristicAlreadySatisfied
    }

    /// Decodes provider-visible association fields without accepting replay history from input.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(NestedAssociationKey.self, forKey: .key)
        tabID = try container.decode(NestedNodeID.self, forKey: .tabID)
        authority = try container.decode(NestedAssociationAuthority.self, forKey: .authority)
        heuristicAlreadySatisfied = try container.decode(Bool.self, forKey: .heuristicAlreadySatisfied)
        supersededKeys = []
    }

    /// Encodes only provider-visible association fields; replay guards are live reducer metadata.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(tabID, forKey: .tabID)
        try container.encode(authority, forKey: .authority)
        try container.encode(heuristicAlreadySatisfied, forKey: .heuristicAlreadySatisfied)
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case tabID
        case authority
        case heuristicAlreadySatisfied
    }
}
