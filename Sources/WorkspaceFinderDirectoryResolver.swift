import Foundation

struct WorkspaceFinderDirectoryCacheKey: Equatable, Sendable {
    var path: String?
    var refreshID: UInt64
}

struct WorkspaceFinderDirectoryCache: Equatable, Sendable {
    var key: WorkspaceFinderDirectoryCacheKey? = nil
    var directoryURL: URL? = nil

    func url(for currentKey: WorkspaceFinderDirectoryCacheKey) -> URL? {
        guard key == currentKey else { return nil }
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

    static func cache(for key: WorkspaceFinderDirectoryCacheKey) async -> WorkspaceFinderDirectoryCache {
        guard let path = key.path else { return WorkspaceFinderDirectoryCache(key: key) }
        let directoryURL = await Task.detached(priority: .utility) {
            existingDirectoryURL(for: path)
        }.value
        return WorkspaceFinderDirectoryCache(key: key, directoryURL: directoryURL)
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
