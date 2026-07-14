import CmuxChangesEngine
import Foundation

/// `mobile.workspace.changes.*` RPC handlers for the native iOS changes viewer.
@MainActor
extension TerminalController {
    /// Routes one native changes method while keeping the god-file dispatch flat.
    func v2MobileChangesDispatch(method: String, params: [String: Any]) async -> V2CallResult {
        switch method {
        case "mobile.workspace.changes.summary":
            return await v2MobileChangesSummary(params: params)
        case "mobile.workspace.changes.file":
            return await v2MobileChangesFile(params: params)
        case "mobile.workspace.changes.context":
            return await v2MobileChangesContext(params: params)
        default:
            return .err(code: "method_not_found", message: "Unknown mobile method", data: ["method": method])
        }
    }

    private func v2MobileChangesSummary(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileChangesResolution(params: params)
        if let error = resolution.error { return error }
        guard let context = resolution.context else {
            return .err(code: "internal_error", message: "Changes context resolution failed", data: nil)
        }
        do {
            let summary = try await context.engine.summary(
                repoRoot: context.repoRoot,
                base: context.base,
                ignoreWhitespace: context.ignoreWhitespace
            )
            return .ok([
                "base_info": [
                    "kind": context.wireBaseKind,
                    "resolved_ref": summary.baseInfo.resolvedRef,
                    "describe": context.baseDescription ?? summary.baseInfo.describe,
                ],
                "totals": [
                    "files": summary.totals.files,
                    "additions": summary.totals.additions,
                    "deletions": summary.totals.deletions,
                ],
                "files": summary.files.map(mobileChangesFilePayload),
                "truncated_file_count": summary.truncatedFileCount,
            ])
        } catch {
            return mobileChangesError(error)
        }
    }

    private func v2MobileChangesFile(params: [String: Any]) async -> V2CallResult {
        guard let path = v2RawString(params, "path"), !path.isEmpty else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }
        if v2HasNonNullParam(params, "old_path"), v2RawString(params, "old_path") == nil {
            return .err(code: "invalid_params", message: "Invalid old_path", data: nil)
        }
        if v2HasNonNullParam(params, "cursor"), v2RawString(params, "cursor") == nil {
            return .err(code: "invalid_params", message: "Invalid cursor", data: nil)
        }
        let resolution = await mobileChangesResolution(params: params)
        if let error = resolution.error { return error }
        guard let context = resolution.context else {
            return .err(code: "internal_error", message: "Changes context resolution failed", data: nil)
        }
        do {
            let diff = try await context.engine.fileDiff(
                repoRoot: context.repoRoot,
                base: context.base,
                path: path,
                oldPath: v2RawString(params, "old_path"),
                cursor: v2RawString(params, "cursor"),
                ignoreWhitespace: context.ignoreWhitespace
            )
            return .ok([
                "hunks": diff.hunks.map(mobileChangesHunkPayload),
                "is_binary": diff.isBinary,
                "too_large": diff.tooLarge,
                "next_cursor": v2OrNull(diff.nextCursor),
            ])
        } catch {
            return mobileChangesError(error)
        }
    }

    private func v2MobileChangesContext(params: [String: Any]) async -> V2CallResult {
        guard let path = v2RawString(params, "path"), !path.isEmpty,
              let startLine = v2Int(params, "start_line"),
              let endLine = v2Int(params, "end_line"),
              startLine >= 1, endLine >= startLine else {
            return .err(code: "invalid_params", message: "Missing or invalid context range", data: nil)
        }
        let resolution = await mobileChangesResolution(params: params)
        if let error = resolution.error { return error }
        guard let context = resolution.context else {
            return .err(code: "internal_error", message: "Changes context resolution failed", data: nil)
        }
        do {
            let rows = try await context.engine.contextLines(
                repoRoot: context.repoRoot,
                base: context.base,
                path: path,
                startLine: startLine,
                endLine: endLine
            )
            return .ok(["rows": rows])
        } catch {
            return mobileChangesError(error)
        }
    }

    private func mobileChangesResolution(
        params: [String: Any]
    ) async -> (
        context: (
            engine: ChangesEngine,
            repoRoot: String,
            base: ChangesBase,
            wireBaseKind: String,
            baseDescription: String?,
            ignoreWhitespace: Bool
        )?,
        error: V2CallResult?
    ) {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return (nil, error)
        }
        guard v2UUID(params, "workspace_id") != nil else {
            return (nil, .err(code: "invalid_params", message: "Missing workspace_id", data: nil))
        }
        guard let baseSpec = params["base_spec"] as? [String: Any],
              let baseKind = baseSpec["kind"] as? String,
              ["working_tree", "last_turn", "branch_base"].contains(baseKind) else {
            return (nil, .err(code: "invalid_params", message: "Missing or invalid base_spec", data: nil))
        }
        if let value = baseSpec["value"], !(value is NSNull), !(value is String) {
            return (nil, .err(code: "invalid_params", message: "Invalid base_spec value", data: nil))
        }
        if v2HasNonNullParam(params, "ignore_whitespace"), v2Bool(params, "ignore_whitespace") == nil {
            return (nil, .err(code: "invalid_params", message: "Invalid ignore_whitespace", data: nil))
        }

        let needsSurface = baseKind == "last_turn"
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: needsSurface) else {
            return (nil, .err(code: "not_found", message: "Workspace context not found", data: nil))
        }
        let workspace = resolved.workspace
        let workingDirectory = [
            resolved.surfaceId.flatMap { workspace.effectivePanelDirectory(panelId: $0) },
            workspace.focusedPanelId.flatMap { workspace.effectivePanelDirectory(panelId: $0) },
            workspace.presentedCurrentDirectory,
            workspace.currentDirectory,
        ].compactMap { value -> String? in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }.first
        guard let workingDirectory else {
            return (nil, .err(code: "unavailable", message: "Workspace directory is unavailable", data: nil))
        }

        let engine = ChangesEngine()
        let repoRoot: String
        do {
            repoRoot = try await engine.repositoryRoot(startingAt: workingDirectory)
        } catch {
            return (nil, .err(code: "not_repository", message: "Workspace is not in a local Git repository", data: nil))
        }

        let base: ChangesBase
        let description: String?
        switch baseKind {
        case "working_tree":
            base = .workingTree
            description = nil
        case "branch_base":
            let requestedBranch = (baseSpec["value"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                base = try await engine.branchBase(
                    repoRoot: repoRoot,
                    defaultBranch: requestedBranch?.isEmpty == false ? requestedBranch : nil
                )
            } catch {
                return (nil, mobileChangesError(error))
            }
            description = requestedBranch?.isEmpty == false ? requestedBranch : nil
        case "last_turn":
            guard let surfaceId = resolved.surfaceId else {
                return (nil, .err(code: "changes_baseline_not_found", message: "No terminal baseline context", data: nil))
            }
            let baseline = AppDelegate.latestAgentTurnDiffBaselineRef(
                storeURL: AppDelegate.agentTurnDiffBaselineStoreURL(),
                repoRoot: repoRoot,
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                sessionId: v2RawString(params, "session_id")
            )
            guard let baseline else {
                return (nil, .err(
                    code: "changes_baseline_not_found",
                    message: "No last-turn baseline exists for this terminal",
                    data: ["workspace_id": workspace.id.uuidString, "surface_id": surfaceId.uuidString]
                ))
            }
            base = .ref(baseline)
            description = "last-turn"
        default:
            return (nil, .err(code: "invalid_params", message: "Invalid base_spec kind", data: nil))
        }

        return ((
            engine: engine,
            repoRoot: repoRoot,
            base: base,
            wireBaseKind: baseKind,
            baseDescription: description,
            ignoreWhitespace: v2Bool(params, "ignore_whitespace") ?? false
        ), nil)
    }

    private func mobileChangesFilePayload(_ file: ChangesFile) -> [String: Any] {
        [
            "path": file.path,
            "old_path": v2OrNull(file.oldPath),
            "status": file.status.rawValue,
            "additions": file.additions,
            "deletions": file.deletions,
            "is_binary": file.isBinary,
            "is_large": file.isLarge,
            "patch_digest": file.patchDigest,
        ]
    }

    private func mobileChangesHunkPayload(_ hunk: DiffHunk) -> [String: Any] {
        [
            "old_start": hunk.oldStart,
            "old_lines": hunk.oldLines,
            "new_start": hunk.newStart,
            "new_lines": hunk.newLines,
            "section_heading": v2OrNull(hunk.sectionHeading),
            "rows": hunk.rows.map { row in
                [
                    "kind": row.kind.rawValue,
                    "old_no": v2OrNull(row.oldNo),
                    "new_no": v2OrNull(row.newNo),
                    "text": row.text,
                ]
            },
        ]
    }

    private func mobileChangesError(_ error: Error) -> V2CallResult {
        guard let changesError = error as? ChangesEngineError else {
            return .err(code: "internal_error", message: "Changes operation failed", data: nil)
        }
        switch changesError {
        case let .invalidBase(ref):
            return .err(code: "invalid_params", message: "Invalid changes base", data: ["ref": ref])
        case .defaultBranchNotFound:
            return .err(code: "changes_base_unavailable", message: "Default branch could not be resolved", data: nil)
        case .gitFailed:
            return .err(code: "git_failed", message: "Git changes operation failed", data: nil)
        case let .invalidPath(path):
            return .err(code: "invalid_params", message: "Invalid repository path", data: ["path": path])
        case let .invalidCursor(cursor):
            return .err(code: "invalid_params", message: "Invalid changes cursor", data: ["cursor": cursor])
        case let .fileNotChanged(path):
            return .err(code: "not_found", message: "Changed file not found", data: ["path": path])
        case let .unreadableText(path):
            return .err(code: "unsupported", message: "File is not readable text", data: ["path": path])
        }
    }
}
