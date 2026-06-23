public import Foundation

/// Equatable mirror of the pin state a row's context menu would apply, carried
/// into ``TabItemView`` solely so the row's `==` reflects pin/unpin changes. The
/// app resolves the live `WorkspaceActionDispatcher.PinState`; the pin label and
/// the pin action stay app-side.
public struct TabItemContextMenuPinState: Equatable {
    public let targetWorkspaceIds: [UUID]
    public let anchorWorkspaceId: UUID
    public let pinned: Bool

    public init(targetWorkspaceIds: [UUID], anchorWorkspaceId: UUID, pinned: Bool) {
        self.targetWorkspaceIds = targetWorkspaceIds
        self.anchorWorkspaceId = anchorWorkspaceId
        self.pinned = pinned
    }
}
