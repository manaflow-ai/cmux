import CmuxWorkspaces
import Foundation

/// The group structure the workspace sidebar draws for one render pass.
///
/// Manual mode projects the user's real groups exactly as the sidebar always
/// has. An automatic Group By mode turns each derived section into a synthetic
/// `WorkspaceGroup` with an empty anchor, so the existing header and row
/// pipeline (SwiftUI list and AppKit table) draws it unchanged. Synthetic
/// groups live only in this value; nothing here writes to `TabManager`, so
/// manual groups and `tabs` order are untouched by the automatic modes.
/// Only building one reads live models, so only the builders are main-actor.
struct SidebarWorkspaceGroupingProjection {
    let mode: SidebarGroupByMode
    /// Groups the sidebar draws, in display order.
    let groups: [WorkspaceGroup]
    let groupsById: [UUID: WorkspaceGroup]
    /// Drawn membership: each workspace's header, synthetic in automatic modes.
    let groupIdByWorkspaceId: [UUID: UUID?]
    let memberWorkspaceIdsByGroupId: [UUID: [UUID]]
    let renderItems: [SidebarWorkspaceRenderItem]
    /// Real manual membership. Row menus that edit manual groups read this.
    let manualGroupIdByWorkspaceId: [UUID: UUID?]
    /// Live anchors of real manual groups, which cannot be filed into a group.
    let manualAnchorWorkspaceIds: Set<UUID>
    /// Section key for each synthetic group id. Empty in manual mode.
    let automaticSectionKeyByGroupId: [UUID: String]

    /// - Parameters:
    ///   - tabs: The window's workspaces in `tabs` order.
    ///   - manualGroups: The window's real workspace groups.
    ///   - mode: The window's Group By mode.
    ///   - collapsedSectionKeys: Automatic sections the user collapsed.
    ///   - automaticInputs: One input per workspace in `tabs` order for the
    ///     active automatic mode; ignored in manual mode. The sidebar passes the
    ///     observer's cached inputs so its body never reads live workspace state
    ///     for grouping.
    @MainActor
    init(
        tabs: [Workspace],
        manualGroups: [WorkspaceGroup],
        mode: SidebarGroupByMode,
        collapsedSectionKeys: Set<String>,
        automaticInputs: [SidebarAutoGroupingInput]
    ) {
        self.mode = mode
        let manualGroupsById = Dictionary(uniqueKeysWithValues: manualGroups.map { ($0.id, $0) })
        let manualMembership = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(
            tabs: tabs,
            groupsById: manualGroupsById
        )
        manualGroupIdByWorkspaceId = manualMembership
        manualAnchorWorkspaceIds = Set(manualGroups.compactMap(\.liveAnchorWorkspaceId))
        guard mode.isAutomatic else {
            groups = manualGroups
            groupsById = manualGroupsById
            groupIdByWorkspaceId = manualMembership
            memberWorkspaceIdsByGroupId = SidebarWorkspaceRenderItem.memberWorkspaceIdsByGroupId(
                tabs: tabs,
                groupsById: manualGroupsById,
                effectiveMembership: manualMembership
            )
            renderItems = SidebarWorkspaceRenderItem.renderItems(
                tabs: tabs,
                groupsById: manualGroupsById,
                orderedGroups: manualGroups,
                effectiveMembership: manualMembership
            )
            automaticSectionKeyByGroupId = [:]
            return
        }

        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let sections = SidebarAutoGrouping(mode: mode).sections(
            for: automaticInputs.filter { tabsById[$0.workspaceId] != nil }
        )
        var sectionGroups: [WorkspaceGroup] = []
        var membership: [UUID: UUID?] = [:]
        var members: [UUID: [UUID]] = [:]
        var sectionKeys: [UUID: String] = [:]
        var orderedTabs: [Workspace] = []
        orderedTabs.reserveCapacity(tabs.count)
        for section in sections {
            let groupId = section.groupId
            // An empty anchor keeps every member a visible row: no workspace
            // is folded into this header the way a manual anchor is.
            sectionGroups.append(WorkspaceGroup(
                id: groupId,
                name: section.title,
                isCollapsed: collapsedSectionKeys.contains(section.key),
                isPinned: false,
                anchor: .empty(groupId),
                customColor: nil,
                iconSymbol: section.symbol
            ))
            sectionKeys[groupId] = section.key
            members[groupId] = section.workspaceIds
            for workspaceId in section.workspaceIds {
                membership[workspaceId] = groupId
                if let tab = tabsById[workspaceId] { orderedTabs.append(tab) }
            }
        }
        let sectionGroupsById = Dictionary(uniqueKeysWithValues: sectionGroups.map { ($0.id, $0) })
        groups = sectionGroups
        groupsById = sectionGroupsById
        groupIdByWorkspaceId = membership
        memberWorkspaceIdsByGroupId = members
        automaticSectionKeyByGroupId = sectionKeys
        // Only the drawn order changes; the caller's `tabs` stays as is.
        renderItems = SidebarWorkspaceRenderItem.renderItems(
            tabs: orderedTabs,
            groupsById: sectionGroupsById,
            orderedGroups: sectionGroups,
            effectiveMembership: membership
        )
    }
}
