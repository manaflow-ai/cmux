import CmuxGit
import Foundation
// MARK: - Mobile workspace changes
extension TerminalController {
    /// Returns cached change totals for 1...64 explicit workspaces.
    ///
    /// IDs never fall back to the current selection. UI-owned workspace lookup
    /// stays on the main actor, while Git service calls run off-main. Remote
    /// provenance and per-workspace failures become `is_repo:false`.
    @MainActor
    func v2MobileWorkspaceChangesSummary(params: [String: Any]) async -> V2CallResult {
        guard let rawIDs = params["workspace_ids"] as? [String],
              (1...64).contains(rawIDs.count) else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "mobile.workspaceChanges.error.workspaceIDsCount",
                    defaultValue: "workspace_ids must contain between 1 and 64 UUIDs"
                ),
                data: nil
            )
        }
        let force = params["force"] as? Bool ?? false
        let workspaceIDs = rawIDs.compactMap(UUID.init(uuidString:))
        guard workspaceIDs.count == rawIDs.count else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "mobile.workspaceChanges.error.invalidWorkspaceIDs",
                    defaultValue: "workspace_ids contains an invalid UUID"
                ),
                data: nil
            )
        }
        let requests = workspaceIDs.map { workspaceID in
            (
                workspaceID,
                mobileWorkspaceChangesDirectoryResolution(workspaceID: workspaceID)
            )
        }
        var summariesByDirectory: [String: WorkspaceChangesSummary] = [:]
        var payloads: [[String: Any]] = []
        payloads.reserveCapacity(requests.count)
        for (workspaceID, resolution) in requests {
            guard case .local(let directory) = resolution else {
                payloads.append(mobileWorkspaceNotARepositoryPayload(workspaceID: workspaceID))
                continue
            }
            let summary: WorkspaceChangesSummary
            if let cached = summariesByDirectory[directory] {
                summary = cached
            } else {
                summary = await MobileHostService.shared.workspaceChangesService
                    .summary(forDirectory: directory, force: force)
                summariesByDirectory[directory] = summary
            }
            payloads.append(mobileWorkspaceChangesSummaryPayload(
                workspaceID: workspaceID,
                summary: summary
            ))
        }
        return .ok(["summaries": payloads])
    }
    /// Returns the changed-file snapshot for one explicit workspace.
    ///
    /// Explicit multi-window routing never falls back to a selected workspace.
    /// Only a local effective directory may cross into the off-main Git service.
    @MainActor
    func v2MobileWorkspaceChangesFiles(params: [String: Any]) async -> V2CallResult {
        guard let workspaceID = explicitMobileWorkspaceChangesID(params: params) else {
            return .err(code: "invalid_params", message: Self.mobileWorkspaceChangesInvalidWorkspaceID, data: nil)
        }
        let resolution = mobileWorkspaceChangesDirectoryResolution(workspaceID: workspaceID)
        guard case .local(let directory) = resolution else {
            return mobileWorkspaceChangesDirectoryErrorResult(resolution, workspaceID: workspaceID)
        }
        guard let changed = try? await MobileHostService.shared.workspaceChangesService
            .changedFiles(forDirectory: directory) else {
            return .err(
                code: "internal_error",
                message: Self.mobileWorkspaceChangesReadFailed,
                data: nil
            )
        }
        guard changed.isRepository, let repoRoot = changed.repoRoot else {
            return .err(code: "not_a_repo", message: Self.mobileWorkspaceChangesNotARepository, data: [
                "workspace_id": workspaceID.uuidString,
            ])
        }
        return .ok([
            "workspace_id": workspaceID.uuidString,
            "repo_root": repoRoot,
            "branch": v2OrNull(changed.branch),
            "base_ref": v2OrNull(changed.baseRef),
            "files": changed.files.map(mobileWorkspaceChangedFilePayload),
            "files_changed": changed.filesChanged,
            "additions": changed.additions,
            "deletions": changed.deletions,
            "truncated": changed.truncated,
        ])
    }
    /// Returns a bounded unified diff for one explicit workspace path.
    ///
    /// Explicit workspace resolution rejects remote provenance before the
    /// package independently validates the network-supplied relative path.
    @MainActor
    func v2MobileWorkspaceChangesFileDiff(params: [String: Any]) async -> V2CallResult {
        guard let workspaceID = explicitMobileWorkspaceChangesID(params: params) else {
            return .err(code: "invalid_params", message: Self.mobileWorkspaceChangesInvalidWorkspaceID, data: nil)
        }
        guard let path = v2RawString(params, "path"), !path.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "mobile.workspaceChanges.error.invalidPath",
                    defaultValue: "Missing or invalid path"
                ),
                data: nil
            )
        }
        let resolution = mobileWorkspaceChangesDirectoryResolution(workspaceID: workspaceID)
        guard case .local(let directory) = resolution else {
            return mobileWorkspaceChangesDirectoryErrorResult(resolution, workspaceID: workspaceID)
        }
        let maxLines = v2Int(params, "max_lines").map {
            min(max($0, 6_000), 1_000_000)
        }
        do {
            let diff = try await MobileHostService.shared.workspaceChangesService.fileDiff(
                forDirectory: directory,
                path: path,
                maxLines: maxLines
            )
            var payload: [String: Any] = [
                "path": diff.path,
                "old_path": v2OrNull(diff.oldPath),
                "status": diff.status.rawValue,
                "is_binary": diff.isBinary,
                "additions": diff.additions,
                "deletions": diff.deletions,
                "unified_diff": diff.unifiedDiff,
                "truncated": diff.truncated,
            ]
            if let totalLineCount = diff.totalLineCount {
                payload["diff_total_lines"] = totalLineCount
            }
            if let contentFingerprint = diff.contentFingerprint {
                payload["content_fingerprint"] = contentFingerprint
            }
            return .ok(payload)
        } catch let error as WorkspaceChangesServiceError {
            return mobileWorkspaceChangesErrorResult(error, path: path)
        } catch {
            return .err(code: "internal_error", message: Self.mobileWorkspaceChangesReadFailed, data: nil)
        }
    }
    /// Returns artifact-compatible metadata for one changed file revision.
    ///
    /// Remote provenance is rejected before repository containment and
    /// current-change authorization validate the network-supplied path.
    @MainActor
    func v2MobileWorkspaceChangesFileStat(params: [String: Any]) async -> V2CallResult {
        guard let context = mobileWorkspaceChangesContentContext(params: params) else {
            return .err(
                code: "invalid_params",
                message: Self.mobileWorkspaceChangesInvalidContentRequest,
                data: nil
            )
        }
        let resolution = mobileWorkspaceChangesDirectoryResolution(workspaceID: context.workspaceID)
        guard case .local(let directory) = resolution else {
            return mobileWorkspaceChangesDirectoryErrorResult(resolution, workspaceID: context.workspaceID)
        }
        do {
            let stat = try await MobileHostService.shared.workspaceChangesService.fileStat(
                forDirectory: directory,
                path: context.path,
                revision: context.revision
            )
            return mobileWorkspaceChangesWireResult(
                stat.artifactStat,
                contentFingerprint: stat.contentFingerprint
            )
        } catch let error as WorkspaceChangesServiceError {
            return mobileWorkspaceChangesContentErrorResult(error, path: context.path)
        } catch {
            return .err(code: "internal_error", message: Self.mobileWorkspaceChangesReadFailed, data: nil)
        }
    }
    /// Returns one bounded byte chunk for one changed file revision.
    ///
    /// The same provenance, containment, authorization, and 3 MiB chunk gates
    /// as `file_stat` run before any bytes are read.
    @MainActor
    func v2MobileWorkspaceChangesFileFetch(params: [String: Any]) async -> V2CallResult {
        guard let context = mobileWorkspaceChangesContentContext(params: params) else {
            return .err(
                code: "invalid_params",
                message: Self.mobileWorkspaceChangesInvalidContentRequest,
                data: nil
            )
        }
        let resolution = mobileWorkspaceChangesDirectoryResolution(workspaceID: context.workspaceID)
        guard case .local(let directory) = resolution else {
            return mobileWorkspaceChangesDirectoryErrorResult(resolution, workspaceID: context.workspaceID)
        }
        let offset = max(0, Int64(v2Int(params, "offset") ?? 0))
        let length = v2Int(params, "length") ?? 0
        do {
            let chunk = try await MobileHostService.shared.workspaceChangesService.fileFetch(
                forDirectory: directory,
                path: context.path,
                revision: context.revision,
                offset: offset,
                length: length
            )
            return mobileWorkspaceChangesWireResult(
                chunk.artifactChunk,
                contentFingerprint: chunk.contentFingerprint
            )
        } catch let error as WorkspaceChangesServiceError {
            return mobileWorkspaceChangesContentErrorResult(error, path: context.path)
        } catch {
            return .err(code: "internal_error", message: Self.mobileWorkspaceChangesReadFailed, data: nil)
        }
    }
    @MainActor
    private func explicitMobileWorkspaceChangesID(params: [String: Any]) -> UUID? {
        guard v2HasNonNullParam(params, "workspace_id") else { return nil }
        return v2UUID(params, "workspace_id")
    }
    @MainActor
    private func mobileWorkspaceChangesDirectoryResolution(
        workspaceID: UUID
    ) -> MobileWorkspaceChangesDirectoryResolution {
        let routingParams: [String: Any] = ["workspace_id": workspaceID.uuidString]
        guard let tabManager = v2ResolveTabManager(params: routingParams),
              let workspace = v2ResolveWorkspace(params: routingParams, tabManager: tabManager) else {
            return .unavailable
        }
        return MobileWorkspaceChangesDirectoryPolicy().resolve(
            presentedDirectory: workspace.presentedCurrentDirectory,
            usesRemoteDirectoryProvenance: workspace.usesRemoteDirectoryProvenance
        )
    }
    private func mobileWorkspaceChangesDirectoryErrorResult(
        _ resolution: MobileWorkspaceChangesDirectoryResolution,
        workspaceID: UUID
    ) -> V2CallResult {
        let isRemote = resolution == .remote
        return .err(
            code: isRemote ? "not_a_repo" : "not_found",
            message: isRemote
                ? Self.mobileWorkspaceChangesNotARepository
                : Self.mobileWorkspaceChangesUnavailable,
            data: ["workspace_id": workspaceID.uuidString]
        )
    }
    private func mobileWorkspaceChangesSummaryPayload(
        workspaceID: UUID,
        summary: WorkspaceChangesSummary
    ) -> [String: Any] {
        guard summary.isRepository, let repoRoot = summary.repoRoot else {
            return mobileWorkspaceNotARepositoryPayload(workspaceID: workspaceID)
        }
        return [
            "workspace_id": workspaceID.uuidString,
            "is_repo": true,
            "repo_root": repoRoot,
            "branch": v2OrNull(summary.branch),
            "base_ref": v2OrNull(summary.baseRef),
            "files_changed": summary.filesChanged,
            "additions": summary.additions,
            "deletions": summary.deletions,
        ]
    }
    private func mobileWorkspaceNotARepositoryPayload(workspaceID: UUID) -> [String: Any] {
        ["workspace_id": workspaceID.uuidString, "is_repo": false]
    }
    private func mobileWorkspaceChangedFilePayload(_ file: WorkspaceChangedFile) -> [String: Any] {
        var payload: [String: Any] = [
            "path": file.path,
            "status": file.status.rawValue,
            "additions": file.additions,
            "deletions": file.deletions,
            "is_binary": file.isBinary,
        ]
        if let oldPath = file.oldPath {
            payload["old_path"] = oldPath
        }
        if file.isApproximate {
            payload["is_approximate"] = true
        }
        return payload
    }
    private func mobileWorkspaceChangesErrorResult(
        _ error: WorkspaceChangesServiceError,
        path: String
    ) -> V2CallResult {
        switch error {
        case .invalidPath:
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "mobile.workspaceChanges.error.pathOutsideRepository",
                    defaultValue: "Path must stay inside the repository"
                ),
                data: ["path": path]
            )
        case .notARepository:
            return .err(code: "not_a_repo", message: Self.mobileWorkspaceChangesNotARepository, data: nil)
        case .fileNotChanged:
            return .err(
                code: "not_found",
                message: String(
                    localized: "mobile.workspaceChanges.error.pathNotChanged",
                    defaultValue: "Path is not in the workspace changes"
                ),
                data: ["path": path]
            )
        case .forbidden:
            return .err(code: "forbidden", message: Self.mobileWorkspaceChangesReadFailed, data: ["path": path])
        case .fileNotFound:
            return .err(code: "file_not_found", message: Self.mobileWorkspaceChangesReadFailed, data: ["path": path])
        case .gitFailure:
            return .err(code: "internal_error", message: Self.mobileWorkspaceChangesReadFailed, data: nil)
        }
    }

    @MainActor
    private func mobileWorkspaceChangesContentContext(
        params: [String: Any]
    ) -> (workspaceID: UUID, path: String, revision: WorkspaceChangesFileRevision)? {
        guard let workspaceID = explicitMobileWorkspaceChangesID(params: params),
              let path = v2RawString(params, "path"),
              !path.isEmpty,
              let revisionRaw = v2RawString(params, "revision"),
              let revision = WorkspaceChangesFileRevision(rawValue: revisionRaw) else {
            return nil
        }
        return (workspaceID, path, revision)
    }

    private func mobileWorkspaceChangesContentErrorResult(
        _ error: WorkspaceChangesServiceError,
        path: String
    ) -> V2CallResult {
        switch error {
        case .invalidPath, .fileNotChanged, .forbidden:
            return .err(code: "forbidden", message: Self.mobileWorkspaceChangesReadFailed, data: ["path": path])
        case .fileNotFound:
            return .err(code: "file_not_found", message: Self.mobileWorkspaceChangesReadFailed, data: ["path": path])
        case .notARepository:
            return .err(code: "not_a_repo", message: Self.mobileWorkspaceChangesNotARepository, data: nil)
        case .gitFailure:
            return .err(code: "internal_error", message: Self.mobileWorkspaceChangesReadFailed, data: nil)
        }
    }

    private func mobileWorkspaceChangesWireResult<T: Encodable>(
        _ value: T,
        contentFingerprint: String? = nil
    ) -> V2CallResult {
        guard let data = try? JSONEncoder().encode(value),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .err(code: "internal_error", message: Self.mobileWorkspaceChangesReadFailed, data: nil)
        }
        if let contentFingerprint {
            object["content_fingerprint"] = contentFingerprint
        }
        return .ok(object)
    }

    private static var mobileWorkspaceChangesInvalidWorkspaceID: String {
        String(
            localized: "mobile.workspaceChanges.error.invalidWorkspaceID",
            defaultValue: "Missing or invalid workspace_id"
        )
    }

    private static var mobileWorkspaceChangesUnavailable: String {
        String(
            localized: "mobile.workspaceChanges.error.workspaceUnavailable",
            defaultValue: "Workspace or effective directory not found"
        )
    }

    private static var mobileWorkspaceChangesNotARepository: String {
        String(
            localized: "mobile.workspaceChanges.error.notRepository",
            defaultValue: "Workspace directory is not a Git repository"
        )
    }

    private static var mobileWorkspaceChangesReadFailed: String {
        String(
            localized: "mobile.workspaceChanges.error.readFailed",
            defaultValue: "Failed to read workspace diff"
        )
    }

    private static var mobileWorkspaceChangesInvalidContentRequest: String {
        String(
            localized: "mobile.workspaceChanges.error.invalidContentRequest",
            defaultValue: "Missing or invalid workspace_id, path, or revision"
        )
    }
}
