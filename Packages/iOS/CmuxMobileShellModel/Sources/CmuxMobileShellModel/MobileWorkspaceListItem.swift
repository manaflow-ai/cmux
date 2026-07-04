import Foundation

/// One drawable item in the mobile workspace list.
///
/// The mobile list mirrors the Mac sidebar's group semantics: a group is shown as
/// a header (representing its anchor workspace) followed by its non-anchor members;
/// collapsing a group hides its members but keeps the header; ungrouped workspaces
/// interleave inline by their position. This is a pure value type so the SwiftUI
/// `List` can consume an immutable snapshot with no store reference below the list
/// boundary.
public enum MobileWorkspaceListItem: Identifiable, Equatable, Sendable {
    /// A collapsible group header. The associated group's anchor workspace is
    /// represented by this header and is never emitted as a separate
    /// ``workspace`` item.
    ///
    /// `hasUnread` is the header's aggregate unread state, mirroring the Mac
    /// sidebar header badge: while the group is expanded it reflects only the
    /// anchor workspace (visible member rows carry their own dots); while
    /// collapsed it reflects the whole group, anchor included, so hidden
    /// member activity is never silently swallowed.
    ///
    /// `depth` is the normalized parent-chain depth used by the view to indent
    /// nested group headers.
    case groupHeader(MobileWorkspaceGroupPreview, hasUnread: Bool, depth: Int = 0)
    /// A workspace row. `indented` is `true` for non-anchor members nested under
    /// a group header, so the view can inset them. `depth` is the containing
    /// group's normalized parent-chain depth.
    case workspace(MobileWorkspacePreview, indented: Bool, depth: Int = 0)

    /// A stable, list-unique identity for SwiftUI diffing. Namespaced by item
    /// kind (`group.` / `workspace.`) so a group header and a workspace row can
    /// never collide even though both wrap UUID-backed ids.
    public var id: String {
        switch self {
        case .groupHeader(let group, _, _):
            return "group.\(group.id.rawValue)"
        case .workspace(let workspace, _, _):
            return "workspace.\(workspace.id.rawValue)"
        }
    }

    /// Build the ordered list items from a workspace list and its groups.
    ///
    /// Mirrors `SidebarWorkspaceRenderItem.renderItems` on the Mac:
    /// - Items follow `workspaces` order. A group header is emitted at its anchor's
    ///   position within its parent.
    /// - The anchor workspace is never a separate row (the header represents it).
    /// - When a group is collapsed, its descendants are skipped (header kept).
    /// - Ungrouped workspaces interleave inline by position.
    ///
    /// A `groupID` referencing a group not present in `groups` (e.g. a transient
    /// payload skew) degrades gracefully: the workspace renders as an ungrouped
    /// row rather than vanishing.
    ///
    /// Non-contiguous members of an already-emitted expanded group stay at
    /// their own spatial position, still indented to mark membership. A
    /// collapsed group still hides those stray members and includes them in
    /// the collapsed unread aggregate.
    ///
    /// - Parameters:
    ///   - workspaces: The workspaces in the Mac's spatial order.
    ///   - groups: The group sections, keyed by id for header lookup.
    /// - Returns: The ordered drawable items.
    public static func items(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview]
    ) -> [MobileWorkspaceListItem] {
        guard !workspaces.isEmpty else { return [] }
        let groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var anchorGroupByWorkspaceID: [MobileWorkspacePreview.ID: MobileWorkspaceGroupPreview] = [:]
        for group in groups where anchorGroupByWorkspaceID[group.anchorWorkspaceID] == nil {
            anchorGroupByWorkspaceID[group.anchorWorkspaceID] = group
        }
        let knownGroupIDs = Set(groupsByID.keys)
        var parentGroupIDByGroupID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview.ID?] = [:]
        for group in groups {
            let parentID: MobileWorkspaceGroupPreview.ID? = {
                guard let parentGroupID = group.parentGroupID,
                      parentGroupID != group.id,
                      knownGroupIDs.contains(parentGroupID) else {
                    return nil
                }
                return parentGroupID
            }()
            parentGroupIDByGroupID[group.id] = parentID
        }

        // Aggregate unread state per group up front (membership can be
        // non-contiguous, so this cannot be folded into the emit loop).
        // Mirrors the Mac header badge: anchor-only while expanded, whole
        // subtree (anchor included) while collapsed.
        var anchorUnreadByGroupID: [MobileWorkspaceGroupPreview.ID: Bool] = [:]
        var directUnreadByGroupID: [MobileWorkspaceGroupPreview.ID: Bool] = [:]
        var childGroupsByParentID: [MobileWorkspaceGroupPreview.ID?: [MobileWorkspaceGroupPreview]] = [:]
        for workspace in workspaces {
            guard let groupID = workspace.groupID, let group = groupsByID[groupID] else { continue }
            directUnreadByGroupID[groupID, default: false] = directUnreadByGroupID[groupID, default: false] || workspace.hasUnread
            if group.anchorWorkspaceID == workspace.id {
                anchorUnreadByGroupID[groupID] = workspace.hasUnread
            }
        }
        for group in groups {
            childGroupsByParentID[parentGroupIDByGroupID[group.id] ?? nil, default: []].append(group)
        }

        var subtreeUnreadByGroupID: [MobileWorkspaceGroupPreview.ID: Bool] = [:]
        func subtreeHasUnread(for groupID: MobileWorkspaceGroupPreview.ID, visiting: inout Set<MobileWorkspaceGroupPreview.ID>) -> Bool {
            if let cached = subtreeUnreadByGroupID[groupID] {
                return cached
            }
            guard visiting.insert(groupID).inserted else {
                return directUnreadByGroupID[groupID, default: false]
            }
            var hasUnread = directUnreadByGroupID[groupID, default: false]
            for childGroup in childGroupsByParentID[Optional(groupID)] ?? [] {
                hasUnread = hasUnread || subtreeHasUnread(for: childGroup.id, visiting: &visiting)
            }
            visiting.remove(groupID)
            subtreeUnreadByGroupID[groupID] = hasUnread
            return hasUnread
        }

        func normalizedParentGroupID(for groupID: MobileWorkspaceGroupPreview.ID) -> MobileWorkspaceGroupPreview.ID? {
            parentGroupIDByGroupID[groupID] ?? nil
        }

        var depthByGroupID: [MobileWorkspaceGroupPreview.ID: Int] = [:]
        func groupDepth(for groupID: MobileWorkspaceGroupPreview.ID, visiting: inout Set<MobileWorkspaceGroupPreview.ID>) -> Int {
            if let cached = depthByGroupID[groupID] {
                return cached
            }
            guard visiting.insert(groupID).inserted else { return 0 }
            defer { visiting.remove(groupID) }
            guard let parentID = normalizedParentGroupID(for: groupID) else {
                depthByGroupID[groupID] = 0
                return 0
            }
            let depth = groupDepth(for: parentID, visiting: &visiting) + 1
            depthByGroupID[groupID] = depth
            return depth
        }

        var items: [MobileWorkspaceListItem] = []
        items.reserveCapacity(workspaces.count + groups.count)
        var emittedHeaders: Set<MobileWorkspaceGroupPreview.ID> = []
        var collapsedByGroupID: [MobileWorkspaceGroupPreview.ID: Bool] = [:]

        func isHiddenByCollapsedAncestor(_ groupID: MobileWorkspaceGroupPreview.ID) -> Bool {
            var visited: Set<MobileWorkspaceGroupPreview.ID> = []
            var cursor = normalizedParentGroupID(for: groupID)
            while let parentID = cursor {
                guard visited.insert(parentID).inserted else { return false }
                if collapsedByGroupID[parentID] == true {
                    return true
                }
                cursor = normalizedParentGroupID(for: parentID)
            }
            return false
        }

        func appendGroup(_ group: MobileWorkspaceGroupPreview) {
            guard emittedHeaders.insert(group.id).inserted else { return }
            var visiting: Set<MobileWorkspaceGroupPreview.ID> = []
            let hasUnread = group.isCollapsed
                ? subtreeHasUnread(for: group.id, visiting: &visiting)
                : anchorUnreadByGroupID[group.id, default: false]
            var depthVisiting: Set<MobileWorkspaceGroupPreview.ID> = []
            let depth = groupDepth(for: group.id, visiting: &depthVisiting)
            items.append(.groupHeader(group, hasUnread: hasUnread, depth: depth))
            collapsedByGroupID[group.id] = group.isCollapsed
        }

        for workspace in workspaces {
            guard let groupID = workspace.groupID,
                  groupsByID[groupID] != nil else {
                items.append(.workspace(workspace, indented: false))
                continue
            }

            if isHiddenByCollapsedAncestor(groupID) {
                continue
            }

            if let anchoredGroup = anchorGroupByWorkspaceID[workspace.id],
               anchoredGroup.id == groupID {
                appendGroup(anchoredGroup)
                continue
            }

            if collapsedByGroupID[groupID] == true {
                continue
            }

            var depthVisiting: Set<MobileWorkspaceGroupPreview.ID> = []
            items.append(.workspace(workspace, indented: true, depth: groupDepth(for: groupID, visiting: &depthVisiting)))
        }

        return items
    }
}
