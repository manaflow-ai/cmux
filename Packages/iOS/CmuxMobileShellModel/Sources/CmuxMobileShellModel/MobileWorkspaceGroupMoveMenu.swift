import CMUXMobileCore
import Foundation

/// Menu model for moving one workspace into a workspace group without dragging.
///
/// Computes the "Move to Group" picker shown in a workspace row's context menu:
/// one entry per candidate group on the workspace's own Mac, plus whether a
/// "Remove from Group" action applies. Selection routes through the same move
/// intent path as drag-and-drop (`MobileWorkspaceMovePolicy`), so the picker can
/// never offer a move the drop path would reject.
public struct MobileWorkspaceGroupMoveMenu: Equatable, Sendable {
    /// One selectable group target in the picker.
    public struct Entry: Equatable, Sendable {
        /// The candidate destination group.
        public let group: MobileWorkspaceGroupPreview
        /// Whether the workspace is already a member of this group. Current
        /// membership renders as a checked, non-actionable item.
        public let isCurrent: Bool
        /// Whether choosing this group is a valid move for the workspace.
        public let isEnabled: Bool

        /// Creates a picker entry.
        /// - Parameters:
        ///   - group: The candidate destination group.
        ///   - isCurrent: Whether the workspace already belongs to the group.
        ///   - isEnabled: Whether the move is valid.
        public init(group: MobileWorkspaceGroupPreview, isCurrent: Bool, isEnabled: Bool) {
            self.group = group
            self.isCurrent = isCurrent
            self.isEnabled = isEnabled
        }
    }

    /// Candidate groups in section order, restricted to the workspace's Mac.
    public let entries: [Entry]
    /// Whether the workspace can leave its current group ("Remove from Group").
    public let canRemoveFromGroup: Bool

    /// Whether the picker offers nothing and should be hidden entirely.
    public var isEmpty: Bool {
        entries.isEmpty && !canRemoveFromGroup
    }

    /// Builds the picker for one workspace against a rendered list snapshot.
    ///
    /// Group anchors get an empty picker: an anchor is its group's header and
    /// moves with the group, matching the host's `workspace.move` rejection.
    ///
    /// - Parameters:
    ///   - workspaces: The displayed workspace order (optimistic when a move is
    ///     already in flight), as validated by ``MobileWorkspaceMovePolicy``.
    ///   - groups: The known workspace groups in section order.
    ///   - movedWorkspaceID: The workspace the context menu belongs to.
    public init(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        movedWorkspaceID: MobileWorkspacePreview.ID
    ) {
        guard let moved = workspaces.first(where: { $0.id == movedWorkspaceID }),
              !groups.contains(where: { $0.liveAnchorWorkspaceID == movedWorkspaceID }) else {
            entries = []
            canRemoveFromGroup = false
            return
        }
        let policy = MobileWorkspaceMovePolicy(workspaces: workspaces, groups: groups)
        entries = groups.filter { group in
            Self.sameMac(group: group, workspace: moved)
        }.map { group in
            let isCurrent = moved.groupID == group.id
            return Entry(
                group: group,
                isCurrent: isCurrent,
                isEnabled: !isCurrent && policy.normalizedIntent(
                    MobileWorkspaceMoveIntent(
                        groupID: group.id,
                        beforeWorkspaceID: nil,
                        movesGroup: false
                    ),
                    movedWorkspaceID: movedWorkspaceID
                ) != nil
            )
        }
        let currentGroupIsKnown = moved.groupID.map { groupID in
            groups.contains(where: { $0.id == groupID })
        } ?? false
        canRemoveFromGroup = currentGroupIsKnown
            && policy.normalizedIntent(
                MobileWorkspaceMoveIntent(
                    groupID: nil,
                    beforeWorkspaceID: nil,
                    movesGroup: false
                ),
                movedWorkspaceID: movedWorkspaceID
            ) != nil
    }

    /// Whether a group and a workspace belong to the same Mac app instance.
    ///
    /// Aggregation stamps `macDeviceID` on groups unconditionally (possibly as
    /// an empty string) but on workspaces only when non-empty, so empty and
    /// `nil` must compare as the same "unscoped" owner.
    private static func sameMac(
        group: MobileWorkspaceGroupPreview,
        workspace: MobileWorkspacePreview
    ) -> Bool {
        CmxMacAppInstanceIdentity(
            macDeviceID: group.macDeviceID ?? "",
            instanceTag: group.macInstanceTag
        ) == CmxMacAppInstanceIdentity(
            macDeviceID: workspace.macDeviceID ?? "",
            instanceTag: workspace.macInstanceTag
        )
    }
}
