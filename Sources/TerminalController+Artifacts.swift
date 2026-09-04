import CmuxArtifacts
import Foundation

extension TerminalController {
    /// Adds one explicitly authorized URL, file, HTML, or text value.
    nonisolated func v2ArtifactsAdd(params: [String: Any]) async -> V2CallResult {
        guard let workspaceID = v2UUID(params, "workspace_id") else {
            return .err(
                code: "not_found",
                message: String(localized: "artifacts.cli.noWorkspace", defaultValue: "No workspace is available for Artifacts"),
                data: nil
            )
        }
        let workspace: Workspace? = await MainActor.run {
            self.artifactsWorkspace(id: workspaceID)
        }
        guard let workspace else {
            return .err(
                code: "not_found",
                message: String(localized: "artifacts.cli.noWorkspace", defaultValue: "No workspace is available for Artifacts"),
                data: nil
            )
        }

        let requestedKind = (params["kind"] as? String).map { ArtifactKind(rawValue: $0) }
        let title = params["title"] as? String
        let mimeType = params["mime_type"] as? String
        let input: ArtifactInput?
        switch (params["input_kind"] as? String)?.lowercased() {
        case "url": input = (params["input"] as? String).map(ArtifactInput.url)
        case "path":
            input = (params["input"] as? String).map { value in
                let url = URL(fileURLWithPath: value)
                return url.hasDirectoryPath ? .directory(url) : .file(url)
            }
        case "html": input = (params["input"] as? String).map(ArtifactInput.html)
        case "text": input = (params["input"] as? String).map(ArtifactInput.text)
        default: input = nil
        }
        guard let input else {
            return .err(
                code: "invalid_params",
                message: String(localized: "artifacts.cli.addInputRequired", defaultValue: "Artifacts add requires exactly one supported input"),
                data: nil
            )
        }
        let metadata = mimeType.map { ["mimeType": $0] } ?? [:]
        guard let record = await workspace.captureArtifact(
            input,
            kind: requestedKind,
            source: .manual,
            title: title,
            metadata: metadata,
            authorization: .explicitUser
        ) else {
            return .err(
                code: "artifact_error",
                message: String(localized: "artifacts.cli.failed", defaultValue: "The artifact request could not be completed."),
                data: nil
            )
        }
        return .ok(["artifact": Self.artifactPayload(record)])
    }

    /// Lists or searches the canonical artifact catalog for the CLI/socket surface.
    nonisolated func v2ArtifactsRead(
        method: String,
        params: [String: Any]
    ) async -> V2CallResult {
        let repository = await MainActor.run { AppDelegate.shared?.artifactRepository }
        guard let repository else {
            return .err(
                code: "unavailable",
                message: String(localized: "artifacts.cli.unavailable", defaultValue: "Artifacts are unavailable before the app finishes launching"),
                data: nil
            )
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
            return .err(
                code: "cancelled",
                message: String(localized: "artifacts.cli.cancelled", defaultValue: "Artifact request cancelled"),
                data: nil
            )
        } catch {
            return .err(
                code: "artifact_error",
                message: String(localized: "artifacts.cli.failed", defaultValue: "The artifact request could not be completed."),
                data: nil
            )
        }
    }

    /// Opens the workspace-owned Artifacts surface through the shared UI action path.
    @MainActor
    func v2ArtifactsOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager),
              workspace.owningTabManager != nil,
              let pane = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first,
              workspace.openOrFocusWorkspaceArtifactsSurface(inPane: pane, focus: true) != nil else {
            return .err(
                code: "not_found",
                message: String(localized: "artifacts.cli.noWorkspace", defaultValue: "No workspace is available for Artifacts"),
                data: nil
            )
        }
        return .ok(["workspace_id": workspace.id.uuidString, "surface": "artifacts"])
    }

    @MainActor
    private func artifactsWorkspace(id: UUID) -> Workspace? {
        let routing: [String: Any] = ["workspace_id": id.uuidString]
        guard let tabManager = v2ResolveTabManager(params: routing) else { return nil }
        return v2ResolveWorkspace(params: routing, tabManager: tabManager)
    }

    /// Handles the legacy v1 `artifacts` command by opening the same surface action.
    @MainActor
    func openArtifactsV1Command(_ args: String) -> String {
        guard args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "open" else {
            return String(localized: "artifacts.cli.usage", defaultValue: "ERROR: Usage: artifacts [open]")
        }
        switch v2ArtifactsOpen(params: [:]) {
        case .ok: return String(localized: "artifacts.cli.opened", defaultValue: "OK Artifacts")
        case .err(_, let message, _):
            return String.localizedStringWithFormat(
                String(localized: "artifacts.cli.errorPrefix", defaultValue: "ERROR: %@"),
                message
            )
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
