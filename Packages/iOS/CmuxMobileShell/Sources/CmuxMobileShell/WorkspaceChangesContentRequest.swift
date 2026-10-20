import Foundation

/// Builds the exact workspace-changes content RPC method and parameter shape.
struct WorkspaceChangesContentRequest {
    let method: String
    let params: [String: Any]

    static func stat(
        workspaceID: String,
        path: String,
        revision: WorkspaceChangesFileRevision
    ) -> WorkspaceChangesContentRequest {
        WorkspaceChangesContentRequest(
            method: "mobile.workspace.changes.file_stat",
            params: baseParams(workspaceID: workspaceID, path: path, revision: revision)
        )
    }

    static func fetch(
        workspaceID: String,
        path: String,
        revision: WorkspaceChangesFileRevision,
        offset: Int64,
        length: Int
    ) -> WorkspaceChangesContentRequest {
        var params = baseParams(workspaceID: workspaceID, path: path, revision: revision)
        params["offset"] = offset
        params["length"] = length
        return WorkspaceChangesContentRequest(
            method: "mobile.workspace.changes.file_fetch",
            params: params
        )
    }

    private static func baseParams(
        workspaceID: String,
        path: String,
        revision: WorkspaceChangesFileRevision
    ) -> [String: Any] {
        [
            "workspace_id": workspaceID,
            "path": path,
            "revision": revision.rawValue,
        ]
    }
}
