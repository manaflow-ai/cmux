import Foundation

extension TerminalController {
    nonisolated func v2RequestedRemotePTYWorkspaceID(params: [String: Any]) -> (
        workspaceId: UUID?,
        error: V2CallResult?
    ) {
        var workspaceId: UUID?
        var invalidWorkspaceID = false
        v2MainSync {
            v2RefreshKnownRefs()
            workspaceId = v2UUID(params, "workspace_id")
            invalidWorkspaceID = v2HasNonNullParam(params, "workspace_id") && workspaceId == nil
        }
        if invalidWorkspaceID {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
            )
        }
        return (workspaceId, nil)
    }

}
