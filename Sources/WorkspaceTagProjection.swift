import Foundation

/// Cached tag index used by the workspace sidebar filter and render pass.
struct WorkspaceTagProjection: Equatable {
    static let empty = WorkspaceTagProjection(availableTags: [], workspaceIdsByTagKey: [:])

    let availableTags: [String]
    let workspaceIdsByTagKey: [String: Set<UUID>]

    func workspaceIds(matching tag: String) -> Set<UUID> {
        workspaceIdsByTagKey[Self.key(for: tag)] ?? []
    }

    static func key(for tag: String) -> String {
        Workspace.customTagFoldingKey(tag)
    }

    @MainActor
    static func make(in workspaces: [Workspace]) -> WorkspaceTagProjection {
        var seenKeys = Set<String>()
        var availableTags: [String] = []
        var workspaceIdsByTagKey: [String: Set<UUID>] = [:]

        for workspace in workspaces {
            for tag in Workspace.normalizedCustomTags(workspace.customTags) {
                let key = Self.key(for: tag)
                if seenKeys.insert(key).inserted {
                    availableTags.append(tag)
                }
                workspaceIdsByTagKey[key, default: []].insert(workspace.id)
            }
        }

        return WorkspaceTagProjection(
            availableTags: availableTags.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            },
            workspaceIdsByTagKey: workspaceIdsByTagKey
        )
    }

    @MainActor
    static func visibleWorkspaces(
        in workspaces: [Workspace],
        matching tag: String?,
        projection: WorkspaceTagProjection
    ) -> [Workspace] {
        guard let tag else { return workspaces }
        let visibleWorkspaceIds = projection.workspaceIds(matching: tag)
        guard !visibleWorkspaceIds.isEmpty else { return [] }
        return workspaces.filter { visibleWorkspaceIds.contains($0.id) }
    }
}
