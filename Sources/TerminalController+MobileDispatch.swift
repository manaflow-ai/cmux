import Foundation

/// `mobile.dispatch.*` RPC handlers for catalog, filesystem, and agent launch.
extension TerminalController {
    func v2MobileDispatch(method: String, params: [String: Any]) async -> V2CallResult {
        switch method {
        case "mobile.dispatch.catalog":
            return v2MobileDispatchCatalog()
        case "mobile.dispatch.fs":
            return await v2MobileDispatchFilesystem(params: params)
        case "mobile.dispatch.launch":
            return await v2MobileDispatchLaunch(params: params)
        default:
            return .err(code: "method_not_found", message: "Unknown mobile method", data: [
                "method": method
            ])
        }
    }

    private func v2MobileDispatchCatalog() -> V2CallResult {
        let home = dispatchDirectoryIndex.homeDirectoryPath
        let providers: [AgentSessionProviderID] = [.claude, .codex]
        let resolver = AgentExecutableResolver(
            configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        )
        let agents = providers.map { provider -> [String: Any] in
            [
                "id": provider.rawValue,
                "name": provider.displayName,
                "installed": (try? resolver.resolve(provider)) != nil,
            ]
        }

        var seenDirectories: Set<String> = []
        var recentDirectories: [[String: Any]] = []
        let fileManager = FileManager.default
        if let tabManager = v2ResolveTabManager(params: [:]) {
            for workspace in tabManager.tabs {
                for candidate in [workspace.presentedCurrentDirectory, workspace.currentDirectory].compactMap({ $0 }) {
                    let path = URL(fileURLWithPath: candidate, isDirectory: true).standardizedFileURL.path
                    var isDirectory: ObjCBool = false
                    guard path != home,
                          seenDirectories.insert(path).inserted,
                          fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                          isDirectory.boolValue else {
                        continue
                    }
                    recentDirectories.append([
                        "path": path,
                        "git": fileManager.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path),
                    ])
                    if recentDirectories.count == 8 { break }
                }
                if recentDirectories.count == 8 { break }
            }
        }

        return .ok([
            "home": home,
            "agents": agents,
            "recent_dirs": recentDirectories,
            "prompt_byte_budget": DispatchAgentCommandBuilder.promptByteBudget,
        ])
    }

    private func v2MobileDispatchFilesystem(params: [String: Any]) async -> V2CallResult {
        guard let operation = v2String(params, "op") else {
            return .err(code: "invalid_params", message: "Missing dispatch filesystem operation", data: nil)
        }
        switch operation {
        case "list":
            guard let path = v2RawString(params, "path"), !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .err(code: "invalid_params", message: "Missing path", data: nil)
            }
            let result = await dispatchDirectoryIndex.list(
                path: path,
                includeHidden: v2Bool(params, "include_hidden") ?? false
            )
            switch result {
            case let .success(listing):
                var payload: [String: Any] = [
                    "path": listing.path,
                    "entries": listing.entries.map(Self.mobileDispatchEntryPayload),
                    "truncated": listing.truncated,
                ]
                if let notice = listing.notice {
                    payload["notice"] = ["code": notice.code, "message": notice.message]
                }
                return .ok(payload)
            case let .failure(.notFound(resolvedPath)):
                return .err(code: "not_found", message: "Directory not found", data: ["path": resolvedPath])
            case let .failure(.unavailable(resolvedPath, message)):
                return .err(code: "unavailable", message: message, data: ["path": resolvedPath])
            }
        case "search":
            guard let query = v2RawString(params, "query") else {
                return .err(code: "invalid_params", message: "Missing query", data: nil)
            }
            let limit = min(max(v2Int(params, "limit") ?? 50, 1), 100)
            let result = await dispatchDirectoryIndex.search(query: query, limit: limit)
            return .ok([
                "query": query,
                "entries": result.entries.map(Self.mobileDispatchEntryPayload),
                "indexing": result.indexing,
                "truncated": result.truncated,
            ])
        default:
            return .err(code: "invalid_params", message: "Unsupported dispatch filesystem operation", data: [
                "op": operation
            ])
        }
    }

    private func v2MobileDispatchLaunch(params: [String: Any]) async -> V2CallResult {
        guard let rawDirectory = v2RawString(params, "directory"),
              !rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "directory_not_found", message: "Directory not found", data: nil)
        }
        let directory = Self.mobileDispatchExpandedPath(
            rawDirectory,
            home: dispatchDirectoryIndex.homeDirectoryPath
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .err(code: "directory_not_found", message: "Directory not found", data: ["directory": directory])
        }
        guard let rawAgentID = v2String(params, "agent_id"),
              let agent = AgentSessionProviderID(rawValue: rawAgentID),
              agent == .claude || agent == .codex else {
            return .err(code: "invalid_params", message: "Unsupported agent_id", data: nil)
        }
        guard let prompt = v2RawString(params, "prompt"),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Prompt must not be empty", data: nil)
        }
        guard prompt.utf8.count <= DispatchAgentCommandBuilder.promptByteBudget else {
            return .err(code: "prompt_too_long", message: "Prompt exceeds the byte budget", data: [
                "prompt_byte_budget": DispatchAgentCommandBuilder.promptByteBudget
            ])
        }

        let resolver = AgentExecutableResolver(
            configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        )
        guard (try? resolver.resolve(agent)) != nil else {
            return .err(
                code: "agent_not_installed",
                message: "\(agent.displayName) is not installed on this Mac",
                data: ["agent_id": agent.rawValue]
            )
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }

        let command: String
        do {
            command = try DispatchAgentCommandBuilder().command(agent: agent, prompt: prompt)
        } catch {
            return .err(code: "invalid_params", message: "Invalid dispatch prompt", data: nil)
        }
        var createParams: [String: Any] = [
            "working_directory": directory,
            "title": Self.mobileDispatchWorkspaceTitle(prompt),
            "focus": false,
            "eager_load_terminal": true,
            "initial_input": command,
        ]
        let createResult = v2WorkspaceCreate(params: createParams, tabManager: tabManager)
        switch createResult {
        case let .ok(rawPayload):
            guard let payload = rawPayload as? [String: Any],
                  let createdWorkspaceID = payload["workspace_id"] as? String,
                  let workspaceID = UUID(uuidString: createdWorkspaceID) else {
                return .err(code: "internal_error", message: "Failed to create dispatch workspace", data: nil)
            }
            tabManager.handlePromptSubmit(workspaceId: workspaceID, message: prompt)
            createParams["workspace_id"] = createdWorkspaceID
            return v2MobileWorkspaceList(
                params: createParams,
                tabManager: tabManager,
                createdWorkspaceID: createdWorkspaceID
            )
        case .err:
            return createResult
        }
    }

    private nonisolated static func mobileDispatchEntryPayload(
        _ entry: DispatchDirectoryIndex.Entry
    ) -> [String: Any] {
        ["path": entry.path, "name": entry.name, "git": entry.git]
    }

    private nonisolated static func mobileDispatchExpandedPath(_ rawPath: String, home: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if trimmed == "~" {
            expanded = home
        } else if trimmed.hasPrefix("~/") {
            expanded = home + String(trimmed.dropFirst())
        } else {
            expanded = trimmed
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    private nonisolated static func mobileDispatchWorkspaceTitle(_ prompt: String) -> String {
        let firstLine = prompt.firstIndex(where: \.isNewline).map { String(prompt[..<$0]) } ?? prompt
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 60 else { return trimmed }
        let prefix = String(trimmed.prefix(60))
        if let boundary = prefix.lastIndex(where: \.isWhitespace) {
            let wordBounded = prefix[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
            if !wordBounded.isEmpty { return wordBounded + "…" }
        }
        return prefix + "…"
    }
}
