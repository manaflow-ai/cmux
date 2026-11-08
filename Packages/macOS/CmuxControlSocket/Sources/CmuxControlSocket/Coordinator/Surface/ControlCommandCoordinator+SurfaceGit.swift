internal import Foundation

/// Surface-scoped Git metadata reporting shared by local and remote shell transports.
extension ControlCommandCoordinator {
    /// `surface.report_git_branch` — record a surface's Git branch.
    func surfaceReportGitBranch(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedSurfaceID = uuid(params, "surface_id")
        if hasNonNull(params, "surface_id"), requestedSurfaceID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let branch = rawString(params, "branch")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty else {
            return .err(code: "invalid_params", message: "Missing branch", data: nil)
        }
        let dirty = surfaceGitDirtyValue(params)
        guard dirty.isValid else {
            return .err(
                code: "invalid_params",
                message: "status must be dirty, clean, or unknown",
                data: nil
            )
        }

        let resolution = context?.controlSurfaceReportGitBranch(
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID,
            branch: branch,
            isDirty: dirty.value
        ) ?? .workspaceNotFound
        return surfaceGitResult(
            resolution,
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID,
            branch: branch,
            isDirty: dirty.value,
            cleared: false
        )
    }

    /// `surface.clear_git_branch` — clear a surface's Git branch.
    func surfaceClearGitBranch(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedSurfaceID = uuid(params, "surface_id")
        if hasNonNull(params, "surface_id"), requestedSurfaceID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let resolution = context?.controlSurfaceClearGitBranch(
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID
        ) ?? .workspaceNotFound
        return surfaceGitResult(
            resolution,
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID,
            branch: nil,
            isDirty: nil,
            cleared: true
        )
    }

    private func surfaceGitDirtyValue(_ params: [String: JSONValue]) -> (isValid: Bool, value: Bool?) {
        if hasNonNull(params, "is_dirty") {
            guard let value = bool(params, "is_dirty") else { return (false, nil) }
            return (true, value)
        }
        guard let status = optionalTrimmedRawString(params, "status")?.lowercased() else {
            return (true, nil)
        }
        switch status {
        case "dirty": return (true, true)
        case "clean": return (true, false)
        case "unknown": return (true, nil)
        default: return (false, nil)
        }
    }

    private func surfaceGitResult(
        _ resolution: ControlSurfaceReportGitBranchResolution,
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        branch: String?,
        isDirty: Bool?,
        cleared: Bool
    ) -> ControlCallResult {
        var payload = surfaceReportSurfaceFields(
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID
        )
        payload["branch"] = orNull(branch)
        payload["is_dirty"] = isDirty.map { .bool($0) } ?? .null
        payload["cleared"] = .bool(cleared)

        switch resolution {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object(payload))
        case .surfaceNotFound:
            return .err(code: "not_found", message: "Surface not found", data: .object(payload))
        case .pending:
            payload["pending"] = .bool(true)
            return .ok(.object(payload))
        case .recorded(let surfaceID):
            payload["surface_id"] = .string(surfaceID.uuidString)
            payload["surface_ref"] = ref(.surface, surfaceID)
            return .ok(.object(payload))
        }
    }
}
