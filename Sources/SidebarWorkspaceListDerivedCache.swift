import Foundation

/// Memoizes the O(N) lookup dictionaries and render items that the workspace
/// sidebar's `body` would otherwise rebuild on every observable tick.
///
/// `VerticalTabsSidebar.body` re-evaluates whenever any of its observed stores
/// publish — `notificationStore` (unread counts churn continuously while agents
/// run), `cmuxConfigStore`, the parent `ContentView`, etc. Most of those ticks
/// are orthogonal to the inputs these structures actually depend on (workspace
/// identity + order, per-workspace `groupId`, and the `workspaceGroups` value
/// array). Rebuilding five O(N) dictionaries plus the render-item traversal on
/// each unrelated tick is steady main-thread churn that, with 130+ workspaces
/// and ~10 concurrent agents, turns into visible sidebar jank.
///
/// This cache keys the derived structures on a cheap value fingerprint of those
/// inputs, so an unrelated tick is a fingerprint comparison instead of five
/// fresh allocations. See https://github.com/manaflow-ai/cmux/issues/5832 (and
/// the per-`Workspace` memoization in #4621, which is complementary).
@MainActor
final class SidebarWorkspaceListDerivedCache {
    /// Captures exactly the inputs the derived structures depend on. Equality is
    /// the memo key: anything not represented here (title, status entries,
    /// badges, git branch, unread counts, …) is correctly ignored.
    struct Fingerprint: Equatable {
        /// Workspace identity + order. Membership or reorder changes this.
        let workspaceIds: [UUID]
        /// Per-workspace `groupId`, parallel to `workspaceIds`. Grouping a
        /// workspace changes this even when membership/order does not.
        let workspaceGroupIds: [UUID?]
        /// Value-type group state (name, collapse, anchor, color, icon). Any
        /// group mutation reassigns the `@Published` array and lands here.
        let groups: [WorkspaceGroup]
    }

    /// The cached, ready-to-read structures consumed by the sidebar body.
    struct Derived {
        let tabIds: [UUID]
        let tabIndexById: [UUID: Int]
        let workspaceById: [UUID: Workspace]
        let workspaceGroupIdByWorkspaceId: [UUID: UUID?]
        let workspaceGroupById: [UUID: WorkspaceGroup]
        let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
        let workspaceRenderItems: [SidebarWorkspaceRenderItem]
        let visibleWorkspaceRowIds: [UUID]
    }

    private var cachedFingerprint: Fingerprint?
    private var cachedDerived: Derived?

    /// Number of times the derived structures were actually (re)built. Exposed so
    /// regression tests can assert that an unrelated observable tick does not
    /// trigger a rebuild of all five structures. Not `@Published`; reading or
    /// writing it never invalidates a SwiftUI view.
    private(set) var rebuildCount: Int = 0

    /// Returns the derived structures for the given inputs, rebuilding only when
    /// the fingerprint changed since the last call.
    func derived(tabs: [Workspace], workspaceGroups: [WorkspaceGroup]) -> Derived {
        let fingerprint = Fingerprint(
            workspaceIds: tabs.map(\.id),
            workspaceGroupIds: tabs.map(\.groupId),
            groups: workspaceGroups
        )
        if let cachedDerived, cachedFingerprint == fingerprint {
            return cachedDerived
        }
        let derived = Self.build(tabs: tabs, workspaceGroups: workspaceGroups)
        cachedFingerprint = fingerprint
        cachedDerived = derived
        rebuildCount += 1
        return derived
    }

    private static func build(
        tabs: [Workspace],
        workspaceGroups: [WorkspaceGroup]
    ) -> Derived {
        let tabIds = tabs.map(\.id)
        let tabIndexById = Dictionary(
            uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset) }
        )
        let workspaceById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let workspaceGroupIdByWorkspaceId = Dictionary(
            uniqueKeysWithValues: tabs.map { ($0.id, $0.groupId) }
        )
        let workspaceGroupById = Dictionary(
            uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) }
        )
        let workspaceGroupMenuSnapshot = WorkspaceGroupMenuSnapshot(
            items: workspaceGroups.map { WorkspaceGroupMenuSnapshot.Item(id: $0.id, name: $0.name) }
        )
        let workspaceRenderItems = SidebarWorkspaceRenderItem.renderItems(
            tabs: tabs,
            groupsById: workspaceGroupById
        )
        let visibleWorkspaceRowIds = workspaceRenderItems.map(\.rowWorkspaceId)
        return Derived(
            tabIds: tabIds,
            tabIndexById: tabIndexById,
            workspaceById: workspaceById,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId,
            workspaceGroupById: workspaceGroupById,
            workspaceGroupMenuSnapshot: workspaceGroupMenuSnapshot,
            workspaceRenderItems: workspaceRenderItems,
            visibleWorkspaceRowIds: visibleWorkspaceRowIds
        )
    }
}
