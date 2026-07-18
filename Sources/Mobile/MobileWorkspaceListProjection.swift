import CmuxWorkspaces
import Foundation

struct MobileWorkspaceListProjection: Hashable {
    let schemaVersion: Int
    let selectedTabID: UUID?
    let groups: [GroupValue]
    let workspaces: [MobileWorkspaceHierarchyProjection.ListValue]

    struct DigestIndex {
        private var values: [UUID: Int] = [:]

        /// Resamples only explicitly invalidated or newly observed workspaces.
        @MainActor
        mutating func refresh(
            tabs: [Workspace],
            resampling workspaceIDs: Set<UUID>,
            digest: (Workspace) -> Int
        ) -> [UUID: Int] {
            let currentIDs = Set(tabs.map(\.id))
            values = values.filter { currentIDs.contains($0.key) }
            for workspace in tabs
                where values[workspace.id] == nil || workspaceIDs.contains(workspace.id) {
                values[workspace.id] = digest(workspace)
            }
            return values
        }
    }

    @MainActor
    init(
        tabs: [Workspace],
        groups: [WorkspaceGroup],
        selectedTabID: UUID?,
        previewSignatures: [UUID: Int]
    ) {
        schemaVersion = MobileWorkspaceHierarchyProjection.schemaVersion
        self.selectedTabID = selectedTabID
        self.groups = groups.map {
            .init(
                id: $0.id,
                name: $0.name,
                isCollapsed: $0.isCollapsed,
                isPinned: $0.isPinned,
                anchorWorkspaceID: $0.anchorWorkspaceId
            )
        }
        workspaces = tabs.map {
            MobileWorkspaceHierarchyProjection(
                workspace: $0,
                previewSignature: previewSignatures[$0.id]
            ).list
        }
    }

    /// Computes the list identity without retaining arrays for the previous
    /// snapshot. Each workspace value is hashed and released before sampling the
    /// next workspace.
    @MainActor
    static func digest(
        tabs: [Workspace],
        groups: [WorkspaceGroup],
        selectedTabID: UUID?,
        previewSignatures: [UUID: Int],
        fallbackNeedsConfirmClose: ((Workspace, UUID) -> Bool)? = nil
    ) -> Int {
        let workspaceDigests = Dictionary(uniqueKeysWithValues: tabs.map { workspace in
            (
                workspace.id,
                workspaceDigest(
                    workspace: workspace,
                    previewSignature: previewSignatures[workspace.id],
                    fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
                )
            )
        })
        return digest(
            tabs: tabs,
            groups: groups,
            selectedTabID: selectedTabID,
            workspaceDigests: workspaceDigests
        )
    }

    @MainActor
    static func workspaceDigest(
        workspace: Workspace,
        previewSignature: Int?,
        fallbackNeedsConfirmClose _: ((Workspace, UUID) -> Bool)? = nil
    ) -> Int {
        var hasher = Hasher()
        let list = MobileWorkspaceHierarchyProjection.observerListValue(
            workspace: workspace,
            previewSignature: previewSignature
        )
        list.hashObserverIdentity(into: &hasher)
        return hasher.finalize()
    }

    @MainActor
    static func digest(
        tabs: [Workspace],
        groups: [WorkspaceGroup],
        selectedTabID: UUID?,
        workspaceDigests: [UUID: Int]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(MobileWorkspaceHierarchyProjection.schemaVersion)
        hasher.combine(selectedTabID)
        hasher.combine(groups.count)
        for group in groups {
            hasher.combine(GroupValue(
                id: group.id,
                name: group.name,
                isCollapsed: group.isCollapsed,
                isPinned: group.isPinned,
                anchorWorkspaceID: group.anchorWorkspaceId
            ))
        }
        hasher.combine(tabs.count)
        for workspace in tabs {
            hasher.combine(workspace.id)
            hasher.combine(workspaceDigests[workspace.id])
        }
        return hasher.finalize()
    }
}
