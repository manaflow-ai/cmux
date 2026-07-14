import Foundation

extension TerminalController {
    /// Searches real directories on the Mac for the iOS task composer. The
    /// filesystem service performs bounded off-main indexing; this main-actor
    /// boundary only validates the request and snapshots open-workspace paths.
    func v2MobileDirectorySearch(params: [String: Any]) async -> V2CallResult {
        guard let rawQuery = params["query"] as? String else {
            return .err(code: "invalid_params", message: "Missing query", data: nil)
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.unicodeScalars.count <= 256 else {
            return .err(code: "invalid_params", message: "Query must contain 1 to 256 characters", data: nil)
        }
        let seedPaths = mobileDirectorySearchSeedPaths()
        do {
            let directories = try await MobileTaskDirectorySearchService.shared.search(
                query: query,
                seedPaths: seedPaths
            )
            return .ok(["directories": directories])
        } catch MobileTaskDirectorySearchService.SearchError.indexTimedOut {
            return .err(
                code: "request_timeout",
                message: "Directory search index timed out",
                data: nil
            )
        } catch MobileTaskDirectorySearchService.SearchError.busy {
            return .err(code: "busy", message: "Directory search is busy", data: nil)
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
