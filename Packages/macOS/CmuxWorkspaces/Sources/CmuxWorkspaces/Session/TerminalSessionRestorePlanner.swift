public import Foundation

/// The small, persistence-format-neutral description used to plan terminal
/// session filtering. Concrete app snapshot DTOs stay in the app target while
/// the scalable workspace/group algorithm lives in ``CmuxWorkspaces``.
public struct TerminalSessionRestoreWorkspaceDescriptor: Sendable, Equatable {
    /// The persisted workspace identity, when one exists.
    public let workspaceID: UUID?
    /// The persisted group identity, when the workspace belongs to a group.
    public let groupID: UUID?
    /// Whether restoring this workspace would recreate a terminal surface.
    public let containsTerminalSurface: Bool

    /// Creates a workspace descriptor for restore planning.
    public init(
        workspaceID: UUID?,
        groupID: UUID?,
        containsTerminalSurface: Bool
    ) {
        self.workspaceID = workspaceID
        self.groupID = groupID
        self.containsTerminalSurface = containsTerminalSurface
    }
}

/// The group metadata needed to remap an anchor after workspaces are removed.
public struct TerminalSessionRestoreGroupDescriptor: Sendable, Equatable {
    /// Stable group identity.
    public let id: UUID
    /// Anchor position among the group's members in the original tab order.
    public let anchorMemberIndex: Int?
    /// Fallback anchor identity for legacy snapshots.
    public let anchorWorkspaceID: UUID?
    /// Whether a pinned group with no live member should remain durable.
    ///
    /// Pinned empty groups use a stable group-header identity instead of a
    /// workspace anchor. Keeping this bit in the neutral planner prevents a
    /// terminal-only filtering pass from accidentally deleting that header.
    public let preserveWhenEmpty: Bool

    /// Creates a group descriptor for restore planning.
    public init(
        id: UUID,
        anchorMemberIndex: Int?,
        anchorWorkspaceID: UUID?,
        preserveWhenEmpty: Bool = false
    ) {
        self.id = id
        self.anchorMemberIndex = anchorMemberIndex
        self.anchorWorkspaceID = anchorWorkspaceID
        self.preserveWhenEmpty = preserveWhenEmpty
    }
}

/// The result of filtering one tab-manager snapshot.
public struct TerminalSessionRestoreWorkspacePlan: Sendable, Equatable {
    /// Original workspace offsets that survive filtering, in tab order.
    public let retainedOriginalOffsets: [Int]
    /// Selected-workspace index after the offsets are compacted.
    public let selectedWorkspaceIndex: Int?
    /// Group anchors remapped into the retained member lists.
    public let groups: [TerminalSessionRestoreGroupPlan]?

    /// Creates a workspace restore plan.
    public init(
        retainedOriginalOffsets: [Int],
        selectedWorkspaceIndex: Int?,
        groups: [TerminalSessionRestoreGroupPlan]?
    ) {
        self.retainedOriginalOffsets = retainedOriginalOffsets
        self.selectedWorkspaceIndex = selectedWorkspaceIndex
        self.groups = groups
    }
}

/// A group with an anchor index adjusted for removed terminal workspaces.
public struct TerminalSessionRestoreGroupPlan: Sendable, Equatable {
    /// Stable group identity.
    public let id: UUID
    /// Anchor index among the retained members, when a member remains.
    public let anchorMemberIndex: Int?
    /// Retained workspace identity at the resolved anchor, when available.
    public let anchorWorkspaceID: UUID?

    /// Creates a remapped group plan.
    public init(id: UUID, anchorMemberIndex: Int?, anchorWorkspaceID: UUID?) {
        self.id = id
        self.anchorMemberIndex = anchorMemberIndex
        self.anchorWorkspaceID = anchorWorkspaceID
    }
}

/// Plans terminal-session filtering without depending on AppKit or app DTOs.
public struct TerminalSessionRestorePlanner: Sendable {
    /// Whether terminal-containing workspaces should be retained.
    public let restoreTerminalSessions: Bool

    /// Creates a planner with a captured preference value.
    public init(restoreTerminalSessions: Bool) {
        self.restoreTerminalSessions = restoreTerminalSessions
    }

    /// Computes retained workspace offsets, selection, and group anchors in
    /// linear time. The caller can apply those offsets to any persistence DTO.
    public func planWorkspaces(
        _ workspaces: [TerminalSessionRestoreWorkspaceDescriptor],
        selectedWorkspaceIndex: Int?,
        groups: [TerminalSessionRestoreGroupDescriptor]?
    ) -> TerminalSessionRestoreWorkspacePlan {
        let retainedOriginalOffsets: [Int] = restoreTerminalSessions
            ? Array(workspaces.indices)
            : workspaces.indices.compactMap { index in
                workspaces[index].containsTerminalSurface ? nil : index
            }

        var compactedIndexByOriginalOffset: [Int: Int] = [:]
        compactedIndexByOriginalOffset.reserveCapacity(retainedOriginalOffsets.count)
        for (compactedIndex, originalOffset) in retainedOriginalOffsets.enumerated() {
            compactedIndexByOriginalOffset[originalOffset] = compactedIndex
        }
        let remappedSelection = selectedWorkspaceIndex.flatMap {
            compactedIndexByOriginalOffset[$0]
        }

        guard let groups else {
            return TerminalSessionRestoreWorkspacePlan(
                retainedOriginalOffsets: retainedOriginalOffsets,
                selectedWorkspaceIndex: remappedSelection,
                groups: nil
            )
        }

        // These indexes avoid rescanning the workspace list for every group.
        var originalMembersByGroup: [UUID: [(offset: Int, workspaceID: UUID?)]] = [:]
        for (offset, workspace) in workspaces.enumerated() {
            guard let groupID = workspace.groupID else { continue }
            originalMembersByGroup[groupID, default: []].append((offset, workspace.workspaceID))
        }
        var retainedMembersByGroup: [UUID: [(originalOffset: Int, workspaceID: UUID?)]] = [:]
        var retainedIndexByOffset: [UUID: [Int: Int]] = [:]
        var retainedIndexByWorkspaceID: [UUID: [UUID: Int]] = [:]
        for originalOffset in retainedOriginalOffsets {
            let workspace = workspaces[originalOffset]
            guard let groupID = workspace.groupID else { continue }
            let memberIndex = retainedMembersByGroup[groupID, default: []].count
            retainedMembersByGroup[groupID, default: []].append((originalOffset, workspace.workspaceID))
            retainedIndexByOffset[groupID, default: [:]][originalOffset] = memberIndex
            if let workspaceID = workspace.workspaceID {
                retainedIndexByWorkspaceID[groupID, default: [:]][workspaceID] = memberIndex
            }
        }

        let groupPlans = groups.compactMap { group -> TerminalSessionRestoreGroupPlan? in
            guard let retainedMembers = retainedMembersByGroup[group.id],
                  !retainedMembers.isEmpty else {
                guard group.preserveWhenEmpty else { return nil }
                return TerminalSessionRestoreGroupPlan(
                    id: group.id,
                    anchorMemberIndex: nil,
                    anchorWorkspaceID: nil
                )
            }
            let originalAnchorOffset = group.anchorMemberIndex.flatMap { index in
                originalMembersByGroup[group.id].flatMap { members in
                    members.indices.contains(index) ? members[index].offset : nil
                }
            }
            let anchorIndex = originalAnchorOffset.flatMap {
                retainedIndexByOffset[group.id]?[$0]
            } ?? group.anchorWorkspaceID.flatMap {
                retainedIndexByWorkspaceID[group.id]?[$0]
            } ?? 0
            return TerminalSessionRestoreGroupPlan(
                id: group.id,
                anchorMemberIndex: anchorIndex,
                anchorWorkspaceID: retainedMembers[anchorIndex].workspaceID
            )
        }

        return TerminalSessionRestoreWorkspacePlan(
            retainedOriginalOffsets: retainedOriginalOffsets,
            selectedWorkspaceIndex: remappedSelection,
            groups: groupPlans.isEmpty ? nil : groupPlans
        )
    }
}
