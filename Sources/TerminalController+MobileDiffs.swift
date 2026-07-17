import CmuxDiffEngine
import Foundation
import os

private let mobileDiffLog = Logger(subsystem: "dev.cmux", category: "mobile-diffs")

extension TerminalController {
    /// Routes the read-only native diff namespace through one app dispatch case.
    func v2MobileDiffDispatch(method: String, params: [String: Any]) async -> V2CallResult {
        let routing = mobileDiffRoutingParams(params)
        let requestedWorkspace = v2String(routing, "workspace_id") ?? "unknown"
        guard v2HasNonNullParam(routing, "workspace_id"), v2UUID(routing, "workspace_id") != nil else {
            return mobileDiffFailure(
                method: method,
                repository: requestedWorkspace,
                code: "workspace_not_found"
            )
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: routing, requireTerminal: false) else {
            return mobileDiffFailure(
                method: method,
                repository: requestedWorkspace,
                code: "workspace_not_found"
            )
        }
        guard let requestedBase = mobileDiffBaseSpec(params) else {
            return mobileDiffFailure(
                method: method,
                repository: requestedWorkspace,
                code: "invalid_params"
            )
        }

        let workspace = resolved.workspace
        var repository = workspace.resolvedWorkingDirectory() ?? ""
        var baseSpec = requestedBase
        if requestedBase.kind == .lastTurn {
            guard let surfaceID = workspace.focusedPanelId,
                  let snapshot = SharedLiveAgentIndex.shared.snapshot(
                      workspaceId: workspace.id,
                      panelId: surfaceID
                  ),
                  let sessionID = AppDelegate.normalizedOpenDiffViewerSessionId(snapshot.sessionId) else {
                return mobileDiffFailure(
                    method: method,
                    repository: repository,
                    code: "baseline_unavailable"
                )
            }
            let storeURL = AppDelegate.agentTurnDiffBaselineStoreURL()
            let workspaceID = workspace.id
            let baseline = await Task.detached(priority: .userInitiated) {
                Self.mobileDiffBaseline(
                    storeURL: storeURL,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    sessionID: sessionID
                )
            }.value
            guard let baseline else {
                return mobileDiffFailure(
                    method: method,
                    repository: repository,
                    code: "baseline_unavailable"
                )
            }
            repository = baseline.repository
            baseSpec = DiffBaseSpec(kind: .lastTurn, value: baseline.commit)
        }
        guard !repository.isEmpty else {
            return mobileDiffFailure(
                method: method,
                repository: requestedWorkspace,
                code: "not_git_repository"
            )
        }

        do {
            let engine = CmuxDiffEngine()
            let ignoreWhitespace = mobileDiffBool(params, camel: "ignoreWhitespace", snake: "ignore_whitespace") ?? false
            let payload: [String: Any]
            let fileCount: Int
            switch method {
            case "mobile.workspace.diffs.summary":
                let summary = try await engine.summary(
                    repositoryPath: repository,
                    baseSpec: baseSpec,
                    ignoreWhitespace: ignoreWhitespace
                )
                payload = mobileDiffSummaryPayload(summary)
                fileCount = summary.files.count
            case "mobile.workspace.diffs.file":
                guard let path = v2String(params, "path") else {
                    return mobileDiffFailure(
                        method: method,
                        repository: repository,
                        code: "invalid_params"
                    )
                }
                let page = try await engine.fileHunks(
                    repositoryPath: repository,
                    path: path,
                    oldPath: v2String(params, "oldPath") ?? v2String(params, "old_path"),
                    baseSpec: baseSpec,
                    ignoreWhitespace: ignoreWhitespace,
                    cursor: mobileDiffInt(params, camel: "cursor", snake: "cursor"),
                    force: mobileDiffBool(params, camel: "force", snake: "force") ?? false
                )
                payload = mobileDiffFilePayload(page)
                fileCount = 1
            case "mobile.workspace.diffs.context":
                guard let path = v2String(params, "path"),
                      let startLine = mobileDiffInt(params, camel: "startLine", snake: "start_line"),
                      let endLine = mobileDiffInt(params, camel: "endLine", snake: "end_line") else {
                    return mobileDiffFailure(
                        method: method,
                        repository: repository,
                        code: "invalid_params"
                    )
                }
                let rows = try await engine.contextRows(
                    repositoryPath: repository,
                    path: path,
                    startLine: startLine,
                    endLine: endLine
                )
                payload = ["rows": rows]
                fileCount = 1
            default:
                return mobileDiffFailure(
                    method: method,
                    repository: repository,
                    code: "method_not_found"
                )
            }
            mobileDiffSuccess(
                method: method,
                repository: repository,
                fileCount: fileCount,
                payload: payload
            )
            return .ok(payload)
        } catch let error as DiffEngineError {
            return mobileDiffFailure(
                method: method,
                repository: repository,
                code: mobileDiffErrorCode(error)
            )
        } catch {
            return mobileDiffFailure(
                method: method,
                repository: repository,
                code: "internal_error"
            )
        }
    }

    private func mobileDiffRoutingParams(_ params: [String: Any]) -> [String: Any] {
        guard !v2HasNonNullParam(params, "workspace_id") else { return params }
        var routing = params
        if let workspace = v2String(params, "workspace")
            ?? v2String(params, "workspaceRef")
            ?? v2String(params, "workspace_ref") {
            routing["workspace_id"] = workspace
        }
        return routing
    }

    private func mobileDiffBaseSpec(_ params: [String: Any]) -> DiffBaseSpec? {
        guard let object = params["baseSpec"] as? [String: Any]
            ?? params["base_spec"] as? [String: Any],
            let rawKind = v2String(object, "kind"),
            let kind = DiffBaseKind(rawValue: rawKind) else {
            return nil
        }
        return DiffBaseSpec(kind: kind, value: v2String(object, "value"))
    }

    private func mobileDiffBool(_ params: [String: Any], camel: String, snake: String) -> Bool? {
        v2Bool(params, camel) ?? v2Bool(params, snake)
    }

    private func mobileDiffInt(_ params: [String: Any], camel: String, snake: String) -> Int? {
        v2StrictInt(params, camel) ?? v2StrictInt(params, snake)
    }

    private func mobileDiffSummaryPayload(_ summary: DiffSummary) -> [String: Any] {
        let files = summary.files.map { file -> [String: Any] in
            [
                "path": file.path,
                "oldPath": v2OrNull(file.oldPath),
                "status": file.status.rawValue,
                "additions": file.additions,
                "deletions": file.deletions,
                "isBinary": file.isBinary,
                "isLarge": file.isLarge,
                "patchDigest": file.patchDigest,
            ]
        }
        return [
            "baseInfo": [
                "kind": summary.baseInfo.kind.rawValue,
                "resolvedRef": summary.baseInfo.resolvedRef,
                "describe": summary.baseInfo.describe,
            ],
            "totals": [
                "files": summary.totals.files,
                "additions": summary.totals.additions,
                "deletions": summary.totals.deletions,
            ],
            "files": files,
            "truncatedFileCount": summary.truncatedFileCount,
        ]
    }

    private func mobileDiffFilePayload(_ page: DiffFilePage) -> [String: Any] {
        let hunks = page.hunks.map { hunk -> [String: Any] in
            [
                "oldStart": hunk.oldStart,
                "oldLines": hunk.oldLines,
                "newStart": hunk.newStart,
                "newLines": hunk.newLines,
                "sectionHeading": v2OrNull(hunk.sectionHeading),
                "rows": hunk.rows.map { row -> [String: Any] in
                    [
                        "kind": row.kind.rawValue,
                        "oldNo": v2OrNull(row.oldNo),
                        "newNo": v2OrNull(row.newNo),
                        "text": row.text,
                    ]
                },
            ]
        }
        return [
            "hunks": hunks,
            "isBinary": page.isBinary,
            "tooLarge": page.tooLarge,
            "nextCursor": v2OrNull(page.nextCursor),
        ]
    }

    private func mobileDiffErrorCode(_ error: DiffEngineError) -> String {
        switch error {
        case .notGitRepository:
            "not_git_repository"
        case .baselineUnavailable:
            "baseline_unavailable"
        case .fileNotFound:
            "not_found"
        case .invalidPath, .invalidRange:
            "invalid_params"
        case .defaultBranchUnavailable:
            "default_branch_unavailable"
        case .commandFailed:
            "git_error"
        }
    }

    private func mobileDiffFailure(
        method: String,
        repository: String,
        code: String
    ) -> V2CallResult {
        mobileDiffLog.error(
            "method=\(method, privacy: .public) repo=\(repository, privacy: .public) files=0 bytes=0 error=\(code, privacy: .public)"
        )
        let message: String
        if code == "workspace_not_found" {
            message = String(
                localized: "rpc.v2.surface.respawn.workspaceNotFound",
                defaultValue: "Workspace not found"
            )
        } else {
            message = code
        }
        return .err(code: code, message: message, data: nil)
    }

    private func mobileDiffSuccess(
        method: String,
        repository: String,
        fileCount: Int,
        payload: [String: Any]
    ) {
        let byteCount = (try? JSONSerialization.data(withJSONObject: payload).count) ?? 0
        mobileDiffLog.info(
            "method=\(method, privacy: .public) repo=\(repository, privacy: .public) files=\(fileCount) bytes=\(byteCount) ok"
        )
    }

    nonisolated private static func mobileDiffBaseline(
        storeURL: URL,
        workspaceID: UUID,
        surfaceID: UUID,
        sessionID: String
    ) -> (repository: String, commit: String)? {
        guard let repository = AppDelegate.latestAgentTurnDiffRepoRoot(
            storeURL: storeURL,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            sessionId: sessionID
        ),
        let data = try? Data(contentsOf: storeURL),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let records = object["records"] as? [[String: Any]] else {
            return nil
        }
        let workspaceKey = workspaceID.uuidString.lowercased()
        let surfaceKey = surfaceID.uuidString.lowercased()
        let candidates = records.compactMap { record -> (commit: String, capturedAt: TimeInterval)? in
            guard AppDelegate.normalizedOpenDiffViewerIdentifier(record["workspaceId"] as? String) == workspaceKey,
                  AppDelegate.normalizedOpenDiffViewerIdentifier(record["surfaceId"] as? String) == surfaceKey,
                  AppDelegate.normalizedOpenDiffViewerSessionId(record["sessionId"] as? String) == sessionID,
                  AppDelegate.normalizedOpenDiffViewerPath(record["repoRoot"] as? String) == repository,
                  let commit = AppDelegate.normalizedOpenDiffViewerIdentifier(record["baseCommit"] as? String) else {
                return nil
            }
            return (commit, (record["capturedAt"] as? NSNumber)?.doubleValue ?? 0)
        }
        guard let latest = candidates.max(by: { $0.capturedAt < $1.capturedAt }) else { return nil }
        return (repository, latest.commit)
    }
}
