import Foundation

/// The stable ordering fields for a mobile workspace snapshot.
public struct MobileWorkspaceOrderSignature: Equatable, Sendable {
    /// The workspace identity.
    public var id: MobileWorkspacePreview.ID
    /// The valid group membership used for ordering.
    public var groupID: MobileWorkspaceGroupPreview.ID?
    /// Whether the workspace belongs to the pinned tier.
    public var isPinned: Bool

    /// Creates an order signature.
    /// - Parameters:
    ///   - id: The workspace identity.
    ///   - groupID: The valid group membership used for ordering.
    ///   - isPinned: Whether the workspace belongs to the pinned tier.
    public init(
        id: MobileWorkspacePreview.ID,
        groupID: MobileWorkspaceGroupPreview.ID?,
        isPinned: Bool
    ) {
        self.id = id
        self.groupID = groupID
        self.isPinned = isPinned
    }
}
