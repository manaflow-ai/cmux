import CmuxArtifacts
import Foundation

extension TerminalController {
    /// Lists or searches the canonical artifact catalog for the CLI/socket surface.
    nonisolated func v2ArtifactsRead(
        method: String,
        params: [String: Any]
    ) async -> V2CallResult {
        let repository = await MainActor.run { AppDelegate.shared?.artifactRepository }
        guard let repository else {
            return .err(code: "unavailable", message: "Artifacts are unavailable before the app finishes launching", data: nil)
        }
        let scope = Self.artifactScope(params["scope"] as? String, params: params)
        do {
            if method == "artifacts.list" {
                let records = try await repository.list(scope: scope)
                return .ok(["artifacts": records.map(Self.artifactPayload)])
            }
            let query = (params["query"] as? String) ?? ""
            let limit = (params["limit"] as? NSNumber)?.intValue ?? (params["limit"] as? Int) ?? 500
            let results = try await repository.search(ArtifactSearchQuery(
                text: query,
                scope: Self.searchScope(scope),
                limit: limit
            ))
            return .ok(["artifacts": results.map { result in
                var payload = Self.artifactPayload(result.record)
                payload["score"] = result.score
                if let snippet = result.snippet { payload["snippet"] = snippet }
                return payload
            }])
        } catch is CancellationError {
            return .err(code: "cancelled", message: "Artifact request cancelled", data: nil)
        } catch {
            return .err(code: "artifact_error", message: String(describing: error), data: nil)
        }
    }

    /// Opens the workspace-owned Artifacts surface through the shared UI action path.
    @MainActor
    func v2ArtifactsOpen(params: [String: Any]) -> V2CallResult {
        let requestedWorkspace = (params["workspace_id"] as? String).flatMap(UUID.init(uuidString:))
        let manager = AppDelegate.shared?.tabManager
        let workspace = requestedWorkspace.flatMap { AppDelegate.shared?.workspaceFor(tabId: $0) }
            ?? manager?.selectedWorkspace
        guard let workspace,
              let owner = workspace.owningTabManager,
              let pane = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first,
              workspace.openOrFocusWorkspaceArtifactsSurface(inPane: pane, focus: true) != nil else {
            return .err(code: "not_found", message: "No workspace is available for Artifacts", data: nil)
        }
        _ = owner
        return .ok(["workspace_id": workspace.id.uuidString, "surface": "artifacts"])
    }

    /// Handles the legacy v1 `artifacts` command by opening the same surface action.
    @MainActor
    func openArtifactsV1Command(_ args: String) -> String {
        guard args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "open" else {
            return "ERROR: Usage: artifacts [open]"
        }
        switch v2ArtifactsOpen(params: [:]) {
        case .ok: return "OK Artifacts"
        case .err(_, let message, _): return "ERROR: \(message)"
        }
    }

    private nonisolated static func artifactScope(_ raw: String?, params: [String: Any]) -> ArtifactScope {
        switch raw?.lowercased() {
        case "workspace":
            return .workspace((params["workspace_id"] as? String) ?? "")
        case "project":
            return .project((params["project_id"] as? String) ?? "")
        default:
            return .global
        }
    }

    private nonisolated static func searchScope(_ scope: ArtifactScope) -> ArtifactSearchScope {
        switch scope {
        case .workspace(let value): .workspace(value)
        case .project(let value): .project(value)
        case .global: .global
        }
    }

    private nonisolated static func artifactPayload(_ record: ArtifactRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "id": record.id.uuidString,
            "kind": record.kind.rawValue,
            "identity_key": record.identityKey,
            "source": record.source.rawValue,
            "created_at": record.createdAt.timeIntervalSince1970,
            "last_seen_at": record.lastSeenAt.timeIntervalSince1970,
            "occurrence_count": record.occurrenceCount,
            "workspace_id": record.ownership.workspaceID ?? NSNull(),
            "project_id": record.ownership.projectID ?? NSNull(),
            "title": record.title ?? NSNull(),
            "metadata": record.metadata,
        ]
        switch record.representation {
        case .url(let value): payload["value"] = value
        case .directory(let value): payload["value"] = value
        case .managedFile(let path, let name): payload["relative_path"] = path; payload["file_name"] = name
        case .inlineText(let value), .inlineHTML(let value): payload["content"] = value
        }
        return payload
    }
}
