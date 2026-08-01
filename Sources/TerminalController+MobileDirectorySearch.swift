import Foundation

extension TerminalController {
    /// Searches indexed directories across mounted volumes for the iOS task
    /// composer and reports the filesystem coverage limits on the wire.
    func v2MobileDirectorySearch(
        params: [String: Any],
        filesystemJobQuota: MobileTaskFilesystemJobQuota
    ) async -> V2CallResult {
        guard let rawQuery = params["query"] as? String else {
            return .err(code: "invalid_params", message: "Missing query", data: nil)
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.unicodeScalars.count <= 256 else {
            return .err(code: "invalid_params", message: "Query must contain 1 to 256 characters", data: nil)
        }
        guard filesystemJobQuota.acquire() else {
            return .err(
                code: "busy",
                message: "Too many filesystem requests are already in progress",
                data: nil
            )
        }
        defer { filesystemJobQuota.release() }

        let seedPaths = mobileDirectorySearchSeedPaths()
        do {
            // Construct per request until the controller composition root can
            // inject the stateless service without colliding with its refactor.
            let result = try await MobileTaskDirectorySearchService().search(
                query: query,
                seedPaths: seedPaths
            )
            return .ok([
                "directories": result.directories,
                "search_scope": result.scope.rawValue,
                "gathering_complete": result.gatheringComplete,
                "filesystem_complete": result.filesystemComplete,
                "truncated": result.truncated,
                "indexed_match_count": result.indexedMatchCount,
            ])
        } catch is CancellationError {
            return .err(code: "cancelled", message: "Directory search was cancelled", data: nil)
        } catch {
            return .err(code: "internal_error", message: "Directory search failed", data: nil)
        }
    }

    private func mobileDirectorySearchSeedPaths() -> [String] {
        guard let app = AppDelegate.shared else { return [] }
        var paths: [String] = []
        var seenWindows = Set<UUID>()
        for summary in app.listMainWindowSummaries() where seenWindows.insert(summary.windowId).inserted {
            guard let tabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for workspace in tabManager.tabs {
                if let path = mobileDirectorySearchNonEmpty(workspace.presentedCurrentDirectory) {
                    paths.append(path)
                }
                for terminal in mobileTerminalPanels(in: workspace) {
                    if let path = workspace.effectivePanelDirectory(
                        panelId: terminal.id,
                        localFallback: mobileDirectorySearchNonEmpty(terminal.directory)
                            ?? mobileDirectorySearchNonEmpty(terminal.requestedWorkingDirectory)
                    ) {
                        paths.append(path)
                    }
                }
            }
        }
        return paths
    }

    private func mobileDirectorySearchNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
