import Foundation

struct WorkspaceFinderDirectoryCache: Equatable, Sendable {
    var path: String? = nil
    var directoryURL: URL? = nil

    func url(for currentPath: String?) -> URL? {
        guard let currentPath, path == currentPath else { return nil }
        return directoryURL
    }
}

enum WorkspaceFinderDirectoryResolver {
    @MainActor
    static func path(for workspace: Workspace) -> String? {
        guard !workspace.isRemoteWorkspace,
              let directory = workspace.sidebarDirectoriesInDisplayOrder().first else {
            return nil
        }
        let path = NSString(string: directory).expandingTildeInPath
        return path.isEmpty ? nil : path
    }

    static func cache(for path: String?) async -> WorkspaceFinderDirectoryCache {
        guard let path else { return WorkspaceFinderDirectoryCache() }
        let directoryURL = await Task.detached(priority: .utility) {
            existingDirectoryURL(for: path)
        }.value
        return WorkspaceFinderDirectoryCache(path: path, directoryURL: directoryURL)
    }

    private nonisolated static func existingDirectoryURL(for path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
