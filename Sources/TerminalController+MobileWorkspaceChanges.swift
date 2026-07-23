import CmuxGit
import Foundation

// MARK: - Mobile workspace changes

extension TerminalController {
    /// Returns cached change totals for 1...64 explicit workspaces.
    ///
    /// `workspace_ids` is validated at the mobile RPC trust boundary and never
    /// falls back to the Mac's current selection. Workspace lookup and effective
    /// directory reads stay on the main actor because `Workspace` is UI-owned;
    /// each `WorkspaceChangesService` call is `nonisolated async`, so every Git
    /// subprocess runs away from the main actor. One workspace's failure is
    /// intentionally converted to `is_repo:false` instead of failing the batch.
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
            (workspaceID, mobileWorkspaceChangesDirectory(workspaceID: workspaceID))
        }
        var summariesByDirectory: [String: WorkspaceChangesSummary] = [:]
        var payloads: [[String: Any]] = []
        payloads.reserveCapacity(requests.count)

        for (workspaceID, directory) in requests {
            guard let directory else {
                payloads.append(mobileWorkspaceNotARepositoryPayload(workspaceID: workspaceID))
                continue
            }
            let summary: WorkspaceChangesSummary
            if let cached = summariesByDirectory[directory] {
                summary = cached
            } else {
                summary = await MobileHostService.shared.workspaceChangesService
                    .summary(forDirectory: directory)
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
    /// The workspace UUID is resolved through the same multi-window routing as
    /// `mobile.workspace.list`; no selected-workspace fallback crosses this
    /// trust boundary. Only the effective directory is copied on the main actor,
    /// then Git and parsing run on the service's global concurrent executor.
    @MainActor
    func v2MobileWorkspaceChangesFiles(params: [String: Any]) async -> V2CallResult {
        guard let workspaceID = explicitMobileWorkspaceChangesID(params: params) else {
            return .err(code: "invalid_params", message: Self.mobileWorkspaceChangesInvalidWorkspaceID, data: nil)
        }
        guard let directory = mobileWorkspaceChangesDirectory(workspaceID: workspaceID) else {
            return .err(code: "not_found", message: Self.mobileWorkspaceChangesUnavailable, data: [
                "workspace_id": workspaceID.uuidString,
            ])
        }
        let changed = await MobileHostService.shared.workspaceChangesService
            .changedFiles(forDirectory: directory)
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
    /// Both the workspace UUID and repository-relative path arrive from the
    /// network. Workspace resolution is explicit and main-actor-bound; the
    /// package service independently rejects absolute paths, lexical escapes,
    /// and symlink escapes before passing the path to Git. Diff generation and
    /// truncation execute off the main actor.
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
        guard let directory = mobileWorkspaceChangesDirectory(workspaceID: workspaceID) else {
            return .err(code: "not_found", message: Self.mobileWorkspaceChangesUnavailable, data: [
                "workspace_id": workspaceID.uuidString,
            ])
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
            return .ok([
                "path": diff.path,
                "old_path": v2OrNull(diff.oldPath),
                "status": diff.status.rawValue,
                "is_binary": diff.isBinary,
                "additions": diff.additions,
                "deletions": diff.deletions,
                "unified_diff": diff.unifiedDiff,
                "truncated": diff.truncated,
                "diff_total_lines": diff.totalLineCount,
            ])
        } catch let error as WorkspaceChangesServiceError {
            return mobileWorkspaceChangesErrorResult(error, path: path)
        } catch {
            return .err(code: "internal_error", message: Self.mobileWorkspaceChangesReadFailed, data: nil)
        }
    }

    /// Returns artifact-compatible metadata for one changed file revision.
    ///
    /// `workspace_id`, `path`, and `revision` arrive across the mobile trust
    /// boundary. Workspace lookup is explicit; `WorkspaceChangesService` then
    /// requires the normalized path to remain contained by the repository and
    /// to belong to the current changed-file authorization snapshot. Rename old
    /// paths are accepted only for the base revision.
    @MainActor
    func v2MobileWorkspaceChangesFileStat(params: [String: Any]) async -> V2CallResult {
        guard let context = mobileWorkspaceChangesContentContext(params: params) else {
            return .err(
                code: "invalid_params",
                message: Self.mobileWorkspaceChangesInvalidContentRequest,
                data: nil
            )
        }
        guard let directory = mobileWorkspaceChangesDirectory(workspaceID: context.workspaceID) else {
            return .err(code: "not_found", message: Self.mobileWorkspaceChangesUnavailable, data: [
                "workspace_id": context.workspaceID.uuidString,
            ])
        }
        do {
            let stat = try await MobileHostService.shared.workspaceChangesService.fileStat(
                forDirectory: directory,
                path: context.path,
                revision: context.revision
            )
            return mobileWorkspaceChangesWireResult(stat)
        } catch let error as WorkspaceChangesServiceError {
            return mobileWorkspaceChangesContentErrorResult(error, path: context.path)
        } catch {
            return .err(code: "internal_error", message: Self.mobileWorkspaceChangesReadFailed, data: nil)
        }
    }

    /// Returns one bounded byte chunk for one changed file revision.
    ///
    /// The same repository-containment and current-change authorization gates
    /// as `file_stat` run before any bytes are read. The package service clamps
    /// each response to the shared 3 MiB artifact chunk policy and reports the
    /// uncapped total size and exact EOF state.
    @MainActor
    func v2MobileWorkspaceChangesFileFetch(params: [String: Any]) async -> V2CallResult {
        guard let context = mobileWorkspaceChangesContentContext(params: params) else {
            return .err(
                code: "invalid_params",
                message: Self.mobileWorkspaceChangesInvalidContentRequest,
                data: nil
            )
        }
        guard let directory = mobileWorkspaceChangesDirectory(workspaceID: context.workspaceID) else {
            return .err(code: "not_found", message: Self.mobileWorkspaceChangesUnavailable, data: [
                "workspace_id": context.workspaceID.uuidString,
            ])
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
            return mobileWorkspaceChangesWireResult(chunk)
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
    private func mobileWorkspaceChangesDirectory(workspaceID: UUID) -> String? {
        let routingParams: [String: Any] = ["workspace_id": workspaceID.uuidString]
        guard let tabManager = v2ResolveTabManager(params: routingParams),
              let workspace = v2ResolveWorkspace(params: routingParams, tabManager: tabManager) else {
            return nil
        }
        return workspace.presentedCurrentDirectory
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

    private func mobileWorkspaceChangesWireResult<T: Encodable>(_ value: T) -> V2CallResult {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .err(code: "internal_error", message: Self.mobileWorkspaceChangesReadFailed, data: nil)
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
