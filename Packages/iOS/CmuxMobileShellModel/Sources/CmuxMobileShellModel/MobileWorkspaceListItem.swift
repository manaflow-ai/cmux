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
    case groupHeader(MobileWorkspaceGroupPreview, hasUnread: Bool)
    /// A workspace row. `indented` is `true` for non-anchor members nested under
    /// a group header, so the view can inset them.
    case workspace(MobileWorkspacePreview, indented: Bool)

    /// A stable, list-unique identity for SwiftUI diffing. Namespaced by item
    /// kind (`group.` / `workspace.`) so a group header and a workspace row can
    /// never collide even though both wrap UUID-backed ids.
    public var id: String {
        switch self {
        case .groupHeader(let group, _):
            return "group.\(group.id.rawValue)"
        case .workspace(let workspace, _):
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

        enum ChildRow {
            case group(MobileWorkspaceGroupPreview)
            case workspace(MobileWorkspacePreview)
        }

        func normalizedParentGroupID(for groupID: MobileWorkspaceGroupPreview.ID) -> MobileWorkspaceGroupPreview.ID? {
            parentGroupIDByGroupID[groupID] ?? nil
        }

        var childRowsByParentID: [MobileWorkspaceGroupPreview.ID?: [ChildRow]] = [:]
        for workspace in workspaces {
            if let anchoredGroup = anchorGroupByWorkspaceID[workspace.id] {
                childRowsByParentID[
                    normalizedParentGroupID(for: anchoredGroup.id),
                    default: []
                ].append(.group(anchoredGroup))
                continue
            }
            if let groupID = workspace.groupID, groupsByID[groupID] != nil {
                if groupsByID[groupID]?.anchorWorkspaceID == workspace.id {
                    continue
                }
                childRowsByParentID[Optional(groupID), default: []].append(.workspace(workspace))
            } else {
                childRowsByParentID[nil, default: []].append(.workspace(workspace))
            }
        }

        var items: [MobileWorkspaceListItem] = []
        items.reserveCapacity(workspaces.count + groups.count)
        var emittedHeaders: Set<MobileWorkspaceGroupPreview.ID> = []

        func appendGroup(_ group: MobileWorkspaceGroupPreview) {
            guard emittedHeaders.insert(group.id).inserted else { return }
            var visiting: Set<MobileWorkspaceGroupPreview.ID> = []
            let hasUnread = group.isCollapsed
                ? subtreeHasUnread(for: group.id, visiting: &visiting)
                : anchorUnreadByGroupID[group.id, default: false]
            items.append(.groupHeader(group, hasUnread: hasUnread))
            guard !group.isCollapsed else { return }
            appendChildren(of: group.id)
        }

        func appendChildren(of parentGroupID: MobileWorkspaceGroupPreview.ID?) {
            for row in childRowsByParentID[parentGroupID] ?? [] {
                switch row {
                case .group(let group):
                    appendGroup(group)
                case .workspace(let workspace):
                    items.append(.workspace(workspace, indented: parentGroupID != nil))
                }
            }
        }

        appendChildren(of: nil)
        return items
    }
}
