public import CmuxNextDaemon
import Foundation
import os

/// The device project list (`project-list-v1`, plans/cmux-next/projects.md) for the pickers:
/// the daemon owns the list; the app only reads it and reports the user's picks.
extension DaemonService {
    /// The daemon's project store; nil before it connects or when it predates `project-list-v1`.
    public var projectStore: ProjectStateClient? {
        guard let connection, supports(DaemonCapability.projectList.rawValue) else { return nil }
        return ProjectStateClient(connection: connection)
    }
}

extension ProjectStateClient {
    /// A picker's folders: the store's list, or nil when the store holds no project at all
    /// (the first import still running, or every source off) or cannot answer, so the caller
    /// scans. A folder the user removed stays gone while the store holds any project.
    public func pickerPaths(query: String?, limit: Int) async -> [String]? {
        guard let listing = try? await list(query: query, limit: limit), listing.storeHasProjects else { return nil }
        return listing.paths
    }

    /// The user picked `path` (Choose Folder): it is listed as the user's own (`project.add`).
    /// Hands the path back; a failed add is logged and never blocks the pick.
    public func picked(_ path: String) async -> String {
        do {
            try await add(path: path, idempotencyKey: UUID().uuidString)
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "projects")
                .error("project.add failed: \(String(describing: error), privacy: .public)")
        }
        return path
    }
}
