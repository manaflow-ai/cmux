/// A stable tree placement whose presentation can be organized without changing its payload.
public protocol CloudTreeOrganizationNode {
    /// Stable placement identity, unique across the tree.
    var id: String { get }
    /// Immediate child placements.
    var children: [Self] { get }
    /// Whether users may move or pin the placement.
    var canOrganize: Bool { get }
    /// Whether a previously unseen placement should lead ordinary saved rows.
    var prefersLeadingPlacement: Bool { get }
    /// Whether this displayed placement belongs to the pinned tier.
    var isPinned: Bool { get }
    /// Copies presentation changes without mutating the source or its domain payload.
    /// - Parameters:
    ///   - children: The arranged children.
    ///   - isPinned: The new pin indicator.
    /// - Returns: A placement with the same identity and domain payload.
    func organized(children: [Self], isPinned: Bool) -> Self
}
