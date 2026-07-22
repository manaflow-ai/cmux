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
    /// The end-of-group drop slot after an expanded group's last visible
    /// member. Emitted only for groups with at least one member row, so drops
    /// before it join the group at its end and drops after it land at root —
    /// the direct touch equivalent of the Mac's boundary pointer lane. Empty
    /// and collapsed groups emit no slot (their below-header gap already
    /// resolves), which keeps header stacks free of thin flapping targets.
    case groupFooter(MobileWorkspaceGroupPreview.ID)

    /// A stable, list-unique identity for SwiftUI diffing. Namespaced by item
    /// kind (`group.` / `workspace.`) so a group header and a workspace row can
    /// never collide even though both wrap UUID-backed ids.
    public var id: String {
        switch self {
        case .groupHeader(let group, _):
            return "group.\(group.id.rawValue)"
        case .workspace(let workspace, _):
            return "workspace.\(workspace.id.rawValue)"
        case .groupFooter(let groupID):
            return "groupFooter.\(groupID.rawValue)"
        }
    }

    /// Build the ordered list items from a workspace list and its groups.
    ///
    /// Mirrors `SidebarWorkspaceRenderItem.renderItems` on the Mac:
    /// - Items follow `workspaces` order. A group header is emitted at the first
    ///   member's position.
    /// - The anchor workspace is never a separate row (the header represents it).
    /// - Expanded groups emit their visible non-anchor members directly after
    ///   the header, followed by one end-of-group drop slot when the run
    ///   rendered at least one member row. Anchor-only groups, collapsed
    ///   groups, and non-contiguous second runs emit no slot.
    /// - When a group is collapsed, its members are skipped and the header remains.
    /// - Ungrouped workspaces interleave inline by position.
    ///
    /// A `groupID` referencing a group not present in `groups` (e.g. a transient
    /// payload skew) degrades gracefully: the workspace renders as an ungrouped
    /// row rather than vanishing.
    ///
    /// Non-contiguous members of an already-emitted group (possible when the
    /// Mac's spatial order interleaves another row between members) do not
    /// re-emit the header: the stray member renders at its own position, still
    /// indented to mark its membership, and is still hidden while its group is
    /// collapsed. Membership is never silently dropped.
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

        // Aggregate unread state per group up front (membership can be
        // non-contiguous, so this cannot be folded into the emit loop).
        // Mirrors the Mac header badge: anchor-only while expanded, whole
        // group (anchor included) while collapsed.
        var anchorUnreadByGroupID: [MobileWorkspaceGroupPreview.ID: Bool] = [:]
        var anyMemberUnreadByGroupID: [MobileWorkspaceGroupPreview.ID: Bool] = [:]
        for workspace in workspaces {
            guard let groupID = workspace.groupID, let group = groupsByID[groupID] else { continue }
            anyMemberUnreadByGroupID[groupID, default: false] = anyMemberUnreadByGroupID[groupID, default: false] || workspace.hasUnread
            if group.anchorWorkspaceID == workspace.id {
                anchorUnreadByGroupID[groupID] = workspace.hasUnread
            }
        }

        var items: [MobileWorkspaceListItem] = []
        items.reserveCapacity(workspaces.count)
        var lastEmittedGroupID: MobileWorkspaceGroupPreview.ID?
        var emittedHeaders: Set<MobileWorkspaceGroupPreview.ID> = []
        var emittedFooters: Set<MobileWorkspaceGroupPreview.ID> = []
        var collapsedByGroupID: [MobileWorkspaceGroupPreview.ID: Bool] = [:]
        var memberRowsInCurrentRun = 0

        // Close a group run with its end-of-group slot when the run rendered
        // at least one member row. Footers are per-group unique (ForEach ids),
        // so a non-contiguous second run never emits another.
        func flushGroupFooter() {
            guard let groupID = lastEmittedGroupID,
                  memberRowsInCurrentRun > 0,
                  collapsedByGroupID[groupID] != true,
                  !emittedFooters.contains(groupID) else {
                memberRowsInCurrentRun = 0
                return
            }
            items.append(.groupFooter(groupID))
            emittedFooters.insert(groupID)
            memberRowsInCurrentRun = 0
        }

        for workspace in workspaces {
            // Resolve the membership only when the referenced group actually
            // exists; otherwise treat the workspace as ungrouped.
            let groupID: MobileWorkspaceGroupPreview.ID? = workspace.groupID
                .flatMap { groupsByID[$0] != nil ? $0 : nil }

            if groupID != lastEmittedGroupID {
                flushGroupFooter()
                lastEmittedGroupID = groupID
                if let groupID, let group = groupsByID[groupID], !emittedHeaders.contains(groupID) {
                    let hasUnread = group.isCollapsed
                        ? anyMemberUnreadByGroupID[groupID, default: false]
                        : anchorUnreadByGroupID[groupID, default: false]
                    items.append(.groupHeader(group, hasUnread: hasUnread))
                    emittedHeaders.insert(groupID)
                    collapsedByGroupID[groupID] = group.isCollapsed
                }
            }

            if let groupID, let group = groupsByID[groupID], group.anchorWorkspaceID == workspace.id {
                // Anchor is represented exclusively by the group header.
                continue
            }

            let isCollapsed = groupID.map { collapsedByGroupID[$0] ?? false } ?? false
            if groupID == nil || !isCollapsed {
                items.append(.workspace(workspace, indented: groupID != nil))
                if groupID != nil, !isCollapsed {
                    memberRowsInCurrentRun += 1
                }
            }
        }
        flushGroupFooter()
        return items
    }
}
